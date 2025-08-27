defmodule ZyzyvaTelemetry.CorrelationTest do
  use ExUnit.Case, async: true
  alias ZyzyvaTelemetry.Correlation

  describe "new/0" do
    test "generates a unique correlation ID" do
      id1 = Correlation.new()
      id2 = Correlation.new()
      id3 = Correlation.new()

      assert is_binary(id1)
      assert String.length(id1) > 0
      assert id1 != id2
      assert id2 != id3
      assert id1 != id3
    end

    test "generates valid UUID v4 format" do
      id = Correlation.new()

      # UUID v4 pattern: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
               id
             )
    end
  end

  describe "with_correlation/2" do
    test "sets correlation ID in process dictionary" do
      correlation_id = "test-correlation-123"

      result =
        Correlation.with_correlation(correlation_id, fn ->
          assert Correlation.get() == correlation_id
          :success
        end)

      assert result == :success
      # Should be cleared after the function
      assert Correlation.get() == nil
    end

    test "restores previous correlation ID after execution" do
      original_id = "original-123"
      Correlation.set(original_id)

      Correlation.with_correlation("temporary-456", fn ->
        assert Correlation.get() == "temporary-456"
      end)

      assert Correlation.get() == original_id
    end

    test "handles exceptions and still restores correlation ID" do
      original_id = "original-123"
      Correlation.set(original_id)

      assert_raise RuntimeError, fn ->
        Correlation.with_correlation("temporary-456", fn ->
          assert Correlation.get() == "temporary-456"
          raise "Test error"
        end)
      end

      assert Correlation.get() == original_id
    end

    test "returns the result of the function" do
      result =
        Correlation.with_correlation("test-id", fn ->
          {:ok, Correlation.get()}
        end)

      assert result == {:ok, "test-id"}
    end
  end

  describe "get/0 and set/1" do
    test "get returns nil when not set" do
      Correlation.clear()
      assert Correlation.get() == nil
    end

    test "set and get correlation ID" do
      Correlation.set("my-correlation-id")
      assert Correlation.get() == "my-correlation-id"
    end

    test "set overwrites previous correlation ID" do
      Correlation.set("first-id")
      assert Correlation.get() == "first-id"

      Correlation.set("second-id")
      assert Correlation.get() == "second-id"
    end
  end

  describe "clear/0" do
    test "clears the correlation ID" do
      Correlation.set("some-id")
      assert Correlation.get() == "some-id"

      Correlation.clear()
      assert Correlation.get() == nil
    end
  end

  describe "get_or_generate/0" do
    test "returns existing correlation ID if set" do
      existing_id = "existing-correlation-id"
      Correlation.set(existing_id)

      assert Correlation.get_or_generate() == existing_id
    end

    test "generates new correlation ID if not set" do
      Correlation.clear()

      generated = Correlation.get_or_generate()
      assert is_binary(generated)
      assert String.length(generated) > 0

      # Should now be set
      assert Correlation.get() == generated
    end

    test "generated ID is valid UUID" do
      Correlation.clear()

      generated = Correlation.get_or_generate()

      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
               generated
             )
    end
  end

  describe "propagate/1" do
    test "adds correlation ID to map" do
      Correlation.set("test-correlation-456")

      original = %{foo: "bar"}
      with_correlation = Correlation.propagate(original)

      assert with_correlation == %{
               foo: "bar",
               correlation_id: "test-correlation-456"
             }
    end

    test "adds correlation ID to keyword list" do
      Correlation.set("test-correlation-789")

      original = [foo: "bar", baz: "qux"]
      with_correlation = Correlation.propagate(original)

      assert Keyword.get(with_correlation, :correlation_id) == "test-correlation-789"
      assert Keyword.get(with_correlation, :foo) == "bar"
      assert Keyword.get(with_correlation, :baz) == "qux"
      assert length(with_correlation) == 3
    end

    test "does not add correlation ID if not set" do
      Correlation.clear()

      original = %{foo: "bar"}
      with_correlation = Correlation.propagate(original)

      assert with_correlation == %{foo: "bar"}
    end

    test "overwrites existing correlation_id in map" do
      Correlation.set("new-correlation")

      original = %{foo: "bar", correlation_id: "old-correlation"}
      with_correlation = Correlation.propagate(original)

      assert with_correlation == %{
               foo: "bar",
               correlation_id: "new-correlation"
             }
    end
  end
end
