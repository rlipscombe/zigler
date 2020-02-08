defmodule Zigler.Parser do
  @moduledoc false

  # all functions that parse zig code

  defstruct [:global, :local]

  import NimbleParsec

  alias Zigler.Nif
  alias Zigler.Zig

  @alphanumeric [?a..?z, ?A..?Z, ?0..?9, ?_]
  @number [?0..?9]

  #############################################################################
  ## post-traversal functions

  defp store_docstring(_rest, content = ["\n", text | _], context = %{docstring: prev}, _line, _offset) do
    {content, %{context | docstring: [prev, String.trim(text), "\n"]}}
  end
  defp store_docstring(_rest, content = ["\n", text | _], context, _line, _offset) do
    {content, Map.put(context, :docstring, [String.trim(text), "\n"])}
  end

  @nif_options ["long", "dirty"]

  # NB: nimble_parsec data is operated on in reverse order.
  defp find_nif_info([arity, "/", name, "/// nif: " | _]) do
    {name, String.to_integer(arity), []}
  end
  defp find_nif_info(["\n" | rest]), do: find_nif_info(rest)
  defp find_nif_info([option | rest]) when option in @nif_options do
    {name, arity, opts} = find_nif_info(rest)
    {name, arity, [String.to_atom(option) | opts]}
  end
  defp find_nif_info(content) do
    raise("parser error #{Enum.reverse(content)}")
  end

  defp store_nif_line_info(_rest, content, context, _line, _offset) do
    {name, arity, opts} = find_nif_info(content)
    {content, Map.put(context, :nif, %{name: name, arity: arity, opts: opts})}
  end

  defp report_param_type(_, [bad_param | _], context = %{nif: %{name: nif_name}}, {line, _}, _) do
    raise CompileError,
      file: context.file,
      line: line,
      description: ~s/nif "#{nif_name}" has unsupported parameter type #{String.trim bad_param}/
  end
  defp report_param_type(_, content, context, _, _), do: {content, context}

  defp report_retval_type(_, [bad_retval | _], context = %{nif: %{name: nif_name}}, {line, _}, _) do
    raise CompileError,
      file: context.file,
      line: line,
      description: ~s/nif "#{nif_name}" has unsupported retval type #{String.trim bad_retval}/
  end
  defp report_retval_type(_, content, context, _, _), do: {content, context}

  defp match_function_if_nif(_rest, content = [name | _], context = %{nif: %{name: name}}, _line, _offset) do
    {content, context}
  end
  defp match_function_if_nif(_, [fn_name | _], context = %{nif: %{name: nif_name}}, {line, _}, _) do
    raise CompileError,
      file: context.file,
      line: line,
      description: ~s/nif docstring expecting "#{nif_name}" not adjacent to function (next to "#{fn_name}")/
  end
  defp match_function_if_nif(_rest, content, context, _line, _offset), do: {content, context}

  defp store_parameter(_rest, content, context = %{params: params}, _line, _offset) do
    [type, ":", _] = Enum.reject(content, &(&1 =~ " "))
    {content, %{context | params: params ++ [type]}}
  end
  defp store_parameter(_rest, content, context , _line, _offset) do
    [type, ":", _] = Enum.reject(content, &(&1 =~ " "))
    {content, Map.put(context, :params, [type])}
  end

  defp store_retval(_rest, content = [type | _], context, _line, _offset) do
    {content, Map.put(context, :retval, type)}
  end

  defp save_if_nif(_rest, content, context = %{nif: nif}, {code_line, _}, _offset) do
    # retrieve the various parameters for the nif.
    params = Map.get(context, :params, [])
    doc = Map.get(context, :docstring, nil)
    retval = context.retval
    found_arity = Enum.count(Zig.adjust_params(params))
    # perform the arity checkt.
    unless nif.arity == found_arity do
      raise CompileError,
        file: context.file,
        line: code_line,
        description: "mismatched arity declaration, expected #{nif.arity}, got #{found_arity}"
    end

    # build the nif struct that we're going to send back with the code.
    res = %Nif{name: String.to_atom(nif.name),
               arity: nif.arity,
               params: params,
               doc: doc,
               retval: retval,
               opts: nif.opts}

    {[res | content], Map.delete(context, :nif)}
  end
  # if it's a plain old function, just ignore all the hullabaloo about nifs.
  defp save_if_nif(_rest, content, context, _, _), do: {content, context}

  defp clear_data(_rest, content, context, {code_line, _}, _offset) do
    nif = context[:nif]

    if nif do
      raise CompileError,
        file: context.file,
        line: code_line - 1,
        description: "missing function header for nif #{nif.name}"
    end

    {content, Map.drop(context, [:nif, :docstring, :params, :retval])}
  end

  #############################################################################
  ## nimble_parsec routines


  whitespace = ascii_string([?\s, ?\n], min: 1)
  blankspace = ignore(ascii_string([?\s], min: 1))
  # note that tabs are forbidden by zig.

  float_literals = Enum.map(~w(f16 f32 f64), &string/1)
  int_literals = Enum.map(~w(u8 i32 i64 c_int c_long isize usize), &string/1)
  array_literals = Enum.map(~w(u8 c_int c_long i32 i64 f16 f32 f64 beam.term), &string/1)
  erlang_literals = Enum.map(~w(?*e.ErlNifEnv e.ErlNifTerm e.ErlNifPid e.ErlNifBinary), &string/1)

  type_literals = Enum.map(~w(bool void beam.env beam.pid beam.atom beam.term beam.binary beam.res), &string/1)
    ++ float_literals
    ++ int_literals
    ++ erlang_literals

  c_string =
    string("[") |> optional(whitespace)
    |> string("*") |> optional(whitespace)
    |> string("c") |> optional(whitespace)
    |> string("]") |> optional(whitespace)
    |> string("u8")
    |> replace("[*c]u8")

  defp clean_up_array(_rest, [aname | _], context, _line, _offset), do: {["[]#{aname}"], context}

  array_or_string =
    string("[") |> optional(whitespace)
    |> string("]") |> optional(whitespace)
    |> choice(array_literals)
    |> post_traverse(:clean_up_array)

  typeinfo = choice(type_literals ++ [c_string, array_or_string])

  unsupported_param_type =
    ascii_string([not: ?,, not: ?)], min: 1)

  parameter =
    optional(whitespace)
    |> ascii_string(@alphanumeric, min: 1)  # identifier
    |> optional(whitespace)
    |> string(":")
    |> optional(whitespace)
    |> concat(choice([typeinfo,
                     unsupported_param_type |> post_traverse(:report_param_type)]))
    |> optional(whitespace)
    |> post_traverse(:store_parameter)

  param_list =
    parameter
    |> repeat(
      string(",")
      |> optional(whitespace)
      |> concat(parameter))

  unsupported_retval_type =
    ascii_string([not: ?{], min: 1)

  function_header =
    repeat(ascii_char([?\s]))
    |> string("fn")
    |> concat(whitespace)
    |> (ascii_string(@alphanumeric, min: 1) |> post_traverse(:match_function_if_nif))
    |> string("(")
    |> optional(param_list)
    |> string(")")
    |> optional(whitespace)
    |> concat(choice([typeinfo |> post_traverse(:store_retval),
                      unsupported_retval_type |> post_traverse(:report_retval_type)]))
    |> repeat(ascii_char(not: ?\n))
    |> string("\n")
    |> post_traverse(:save_if_nif)

  nif_line =
    repeat(ascii_char([?\s]))
    |> string("/// nif: ")
    |> ascii_string(@alphanumeric, min: 1)
    |> string("/")
    |> ascii_string(@number, min: 1)
    |> repeat(ignore(ascii_char([?\s])))
    |> optional(
      ascii_string(@alphanumeric, min: 1)
      |> repeat(ignore(ascii_char([?\s]))))
    |> string("\n")
    |> post_traverse(:store_nif_line_info)
    |> reduce({Enum, :join, []})

  #############################################################################
  ## INITIALIZATION
  ##
  ## used to initialize nimble_parsec with a struct instead of a generic map.
  ## should be prepended to most things which are turned into parsecs.  You
  ## can also pass information into a parsec function to preseed the context.

  initialize = post_traverse(empty(), :initializer)

  defp initializer(_, _, context, _, _), do: {[], struct(__MODULE__, context)}

  if Mix.env == :test do
    defparsec :parser_initializer, initialize
  end

  #############################################################################
  ## DOCSTRING PARSING

  docstring_line =
    optional(blankspace)
    |> ignore(string("///"))
    |> optional(blankspace)
    |> lookahead_not(string("nif:"))
    |> optional(utf8_string([not: ?\n], min: 1))
    |> ignore(string("\n"))
    |> post_traverse(:register_docstring_line)

  # empty docstring line.
  defp register_docstring_line(_rest, [], context = %{local: {:doc, doc}}, _, _) do
    {[], %{context | local: {:doc, [doc, ?\n]}}}
  end
  defp register_docstring_line(_rest, [], context, _, _) do
    {[], %{context | local: nil}}
  end
  defp register_docstring_line(_rest, [content], context = %{local: {:doc, doc}}, _, _) do
    {[], %{context | local: {:doc, [doc, ?\n | String.trim(content)]}}}
  end
  defp register_docstring_line(_rest, [content], context, _, _) do
    {[], %{context | local: {:doc, String.trim(content)}}}
  end

  docstring = repeat(docstring_line)

  if Mix.env == :test do
    defparsec :parse_docstring_line, concat(initialize, docstring_line)
    defparsec :parse_docstring,      concat(initialize, docstring)
  end

  #defparsec :parse_nif_line, nif_line
  #defparsec :parse_function_header, function_header

  # NB: zig does not allow windows-style crlf line breaks.

  line =
    utf8_string([not: ?\n], min: 1)
    |> string("\n")
    |> post_traverse(:clear_data)
    |> reduce({Enum, :join, []})

  empty_line = string("\n")

  by_line =
    repeat(choice([
      docstring,
      function_header,
      line,
      empty_line
    ]))

  defparsec :zig_by_line, by_line

  @spec parse(String.t, Path.t, non_neg_integer) :: %{code: iodata, nifs: [Zigler.Nif.t]}
  def parse(code, file, line) do
    # prepend a comment saving the file and line metadata.
    marker_comment = "// #{file} line: #{line}\n"

    {:ok, new_code, _, _, _, _} = zig_by_line(code, line: line, context: %{file: file})

    Enum.reduce(new_code, %{code: marker_comment, nifs: [], imports: []}, fn
      res = %Zigler.Nif{}, acc = %{nifs: nifs} ->
        %{acc | nifs: [res | nifs]}
      any, acc = %{code: code} ->
        %{acc | code: [code, any]}
    end)
  end
end
