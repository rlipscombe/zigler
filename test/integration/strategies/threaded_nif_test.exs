defmodule ZiglerTest.Integration.Strategies.ThreadedNifTest do

  use ExUnit.Case, async: true
  use Zig, link_libc: true

  @moduletag :threaded

  ~Z"""
  /// nif: threaded_forty_seven/0 threaded
  fn threaded_forty_seven() i32 {
    // sleep for 2 seconds
    std.time.sleep(2000000000);
    return 47;
  }
  """
  test "threaded nifs can sleep for a while" do
    start = DateTime.utc_now
    assert 47 == threaded_forty_seven()
    elapsed = DateTime.utc_now |> DateTime.diff(start)
    assert elapsed >= 2 and elapsed < 4
  end

  ~Z"""
  /// nif: self_test/0 threaded
  fn self_test(env: beam.env) void {
    var self = beam.self(env) catch unreachable;
    _ = beam.send(env, self, beam.make_atom(env, "self"));
  }
  """
  test "self is as you expect" do
    self_test()
    assert_received :self
  end

  ~Z"""
  /// nif: threaded_void/1 threaded
  fn threaded_void(env: beam.env, parent: beam.pid) void {
    // sleep for 50 ms
    std.time.sleep(50_000_000);

    _ = beam.send(env, parent, beam.make_atom(env, "threaded"));
  }
  """
  test "threaded nifs can have a void return and parameters" do
    assert :ok = threaded_void(self())
    assert_receive :threaded
  end

  test "you can run threaded nifs more than once safely" do
    assert :ok = threaded_void(self())
    assert :ok = threaded_void(self())
  end

  ~Z"""
  /// nif: threaded_sum/1 threaded
  fn threaded_sum(list: []i64) i64 {
    var result : i64 = 0;
    for (list) | val | { result += val; }
    return result;
  }
  """
  test "threaded nifs can have an slice input" do
    assert 5050 == 1..100 |> Enum.to_list |> threaded_sum
  end

  ~Z"""
  /// nif: threaded_string/1 threaded
  fn threaded_string(str: []u8) usize {
    return str.len;
  }
  """
  test "threaded nifs can have an string input" do
    assert 6 = threaded_string("foobar")
  end

  test "if you pass an incorrect value in you get fce" do
    assert_raise FunctionClauseError, fn ->
      threaded_string(:foobar)
    end
  end

  ~Z"""
  /// nif: threaded_with_yield/0 threaded
  fn threaded_with_yield() i32 {
    beam.yield() catch return 0;
    return 47;
  }
  """
  test "yielding nif code can be run in a threaded fn" do
    assert 47 == threaded_with_yield()
  end

  ~Z"""
  /// nif: threaded_with_yield_cancel/1 threaded
  fn threaded_with_yield_cancel(env: beam.env, pid: beam.pid) !void {
    var leak = try beam.allocator.alloc(u8, 10_000_000);
    defer {
      _ = beam.send(env, pid, beam.make_atom(env, "done"));
      beam.allocator.free(leak);
    }

    _ = beam.send(env, pid, beam.make_atom(env, "started"));

    while (true) {
      std.time.sleep(10_000);
      try beam.yield();
    }
  }
  """
  test "threaded function can be cancelled" do
    start_memory = :erlang.memory()[:total]
    this = self()
    child = spawn(fn -> threaded_with_yield_cancel(this) end)
    assert_receive :started
    mid_memory = :erlang.memory()[:total]

    assert (mid_memory - start_memory) > 8_000_000

    Process.exit(child, :kill)

    assert_receive :done

    Process.sleep(100)

    final_memory = :erlang.memory()[:total]
    assert (mid_memory - final_memory) > 8_000_000
  end

  ~Z"""
  /// nif: threaded_with_abandonment/1 threaded
  fn threaded_with_abandonment(env: beam.env, pid: beam.pid) !void {
    var leak = try beam.allocator.alloc(u8, 10_000_000);
    defer {
      _ = beam.send(env, pid, beam.make_atom(env, "done"));
      beam.allocator.free(leak);
    }

    _ = beam.send(env, pid, beam.make_atom(env, "started"));

    std.time.sleep(1_000_000_000);
    try beam.yield();
  }
  """
  test "threaded function can be abandoned" do
    start_memory = :erlang.memory()[:total]
    this = self()
    child = spawn(fn -> threaded_with_abandonment(this) end)
    assert_receive :started
    mid_memory = :erlang.memory()[:total]

    assert (mid_memory - start_memory) > 8_000_000

    Process.exit(child, :kill)

    refute_receive :done

    Process.sleep(1000)

    assert_receive :done

    final_memory = :erlang.memory()[:total]
    assert (mid_memory - final_memory) > 8_000_000
  end
end
