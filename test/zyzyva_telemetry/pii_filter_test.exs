defmodule ZyzyvaTelemetry.PIIFilterTest do
  use ExUnit.Case, async: true

  alias ZyzyvaTelemetry.PIIFilter

  describe "filter/1 with maps" do
    test "filters sensitive keys" do
      data = %{password: "secret123", username: "john"}

      result = PIIFilter.filter(data)

      assert result.password == "[FILTERED]"
      assert result.username == "john"
    end

    test "filters tokens and API keys" do
      data = %{
        api_key: "sk_live_abc123",
        access_token: "token_xyz",
        name: "John"
      }

      result = PIIFilter.filter(data)

      assert result.api_key == "[FILTERED]"
      assert result.access_token == "[FILTERED]"
      assert result.name == "John"
    end

    test "filters nested maps" do
      data = %{
        user: %{
          password: "secret",
          email: "user@example.com"
        }
      }

      result = PIIFilter.filter(data)

      assert result.user.password == "[FILTERED]"
      assert result.user.email == "u***@example.com"
    end

    test "masks emails in string values" do
      data = %{message: "Contact us at support@example.com"}

      result = PIIFilter.filter(data)

      assert result.message == "Contact us at s***@example.com"
    end
  end

  describe "filter/1 with keyword lists" do
    test "filters sensitive keys in keyword list" do
      data = [password: "secret123", username: "john"]

      result = PIIFilter.filter(data)

      assert Keyword.get(result, :password) == "[FILTERED]"
      assert Keyword.get(result, :username) == "john"
    end

    test "filters nested keyword lists" do
      data = [user: [password: "secret", name: "John"]]

      result = PIIFilter.filter(data)

      user = Keyword.get(result, :user)
      assert Keyword.get(user, :password) == "[FILTERED]"
      assert Keyword.get(user, :name) == "John"
    end
  end

  describe "filter/1 when disabled" do
    setup do
      original_config = Application.get_env(:zyzyva_telemetry, :pii_filter, [])

      Application.put_env(:zyzyva_telemetry, :pii_filter, enabled: false)

      on_exit(fn ->
        Application.put_env(:zyzyva_telemetry, :pii_filter, original_config)
      end)

      :ok
    end

    test "does not filter when disabled" do
      data = %{password: "secret123", email: "user@example.com"}

      result = PIIFilter.filter(data)

      assert result.password == "secret123"
      assert result.email == "user@example.com"
    end
  end

  describe "mask_email/1" do
    test "masks short email addresses" do
      assert PIIFilter.mask_email("a@b.co") == "a***@b.co"
    end

    test "masks typical email addresses" do
      assert PIIFilter.mask_email("user@example.com") == "u***@example.com"
    end

    test "masks long email addresses" do
      assert PIIFilter.mask_email("very.long.email@company.com") == "v***@company.com"
    end

    test "returns non-string values unchanged" do
      assert PIIFilter.mask_email(nil) == nil
      assert PIIFilter.mask_email(123) == 123
    end

    test "returns invalid emails unchanged" do
      assert PIIFilter.mask_email("not-an-email") == "not-an-email"
    end
  end

  describe "mask_phone/1" do
    test "masks phone numbers" do
      assert PIIFilter.mask_phone("555-123-4567") =~ "4567"
      assert PIIFilter.mask_phone("555-123-4567") =~ "***"
    end

    test "masks phone numbers of different lengths" do
      result = PIIFilter.mask_phone("1234567890")
      assert String.ends_with?(result, "7890")
      assert String.length(result) == 10
    end

    test "returns non-string values unchanged" do
      assert PIIFilter.mask_phone(nil) == nil
    end
  end

  describe "credit_card?/1" do
    test "detects valid credit card numbers (Visa)" do
      assert PIIFilter.credit_card?("4532015112830366")
    end

    test "detects valid credit card with spaces" do
      assert PIIFilter.credit_card?("4532 0151 1283 0366")
    end

    test "detects valid credit card with dashes" do
      assert PIIFilter.credit_card?("4532-0151-1283-0366")
    end

    test "rejects invalid credit card numbers" do
      refute PIIFilter.credit_card?("1234567890123456")
    end

    test "rejects non-numeric strings" do
      refute PIIFilter.credit_card?("not-a-card")
    end

    test "rejects short numbers" do
      refute PIIFilter.credit_card?("123456")
    end

    test "rejects non-strings" do
      refute PIIFilter.credit_card?(nil)
      refute PIIFilter.credit_card?(123_456)
    end
  end

  describe "mask_credit_card/1" do
    test "masks credit card numbers" do
      assert PIIFilter.mask_credit_card("4532015112830366") == "****-****-****-0366"
    end

    test "masks credit card with spaces" do
      assert PIIFilter.mask_credit_card("4532 0151 1283 0366") == "****-****-****-0366"
    end

    test "returns non-string values unchanged" do
      assert PIIFilter.mask_credit_card(nil) == nil
    end
  end

  describe "integration tests" do
    test "filters complex nested structures" do
      data = %{
        user: %{
          name: "John Doe",
          email: "john.doe@example.com",
          password: "super_secret",
          phone: "555-123-4567"
        },
        payment: %{
          card_number: "4532015112830366",
          api_key: "sk_live_test123"
        },
        metadata: [
          token: "bearer_xyz",
          description: "Email me at admin@test.com"
        ]
      }

      result = PIIFilter.filter(data)

      # User data
      assert result.user.name == "John Doe"
      assert result.user.email == "j***@example.com"
      assert result.user.password == "[FILTERED]"
      assert result.user.phone =~ "4567"

      # Payment data
      assert result.payment.card_number == "****-****-****-0366"
      assert result.payment.api_key == "[FILTERED]"

      # Metadata
      assert Keyword.get(result.metadata, :token) == "[FILTERED]"
      assert Keyword.get(result.metadata, :description) =~ "a***@test.com"
    end

    test "detects sensitive keys with various naming conventions" do
      data = %{
        password_field: "test1",
        user_password: "test2",
        auth_token: "test3",
        apikey: "test4",
        client_secret: "test5",
        normal_field: "keep_this"
      }

      result = PIIFilter.filter(data)

      assert result.password_field == "[FILTERED]"
      assert result.user_password == "[FILTERED]"
      assert result.auth_token == "[FILTERED]"
      assert result.apikey == "[FILTERED]"
      assert result.client_secret == "[FILTERED]"
      assert result.normal_field == "keep_this"
    end

    test "filters SSN patterns" do
      data = %{message: "My SSN is 123-45-6789"}

      result = PIIFilter.filter(data)

      assert result.message == "My SSN is ***-**-****"
    end

    test "handles nil and empty values" do
      data = %{
        password: nil,
        email: "",
        name: "John"
      }

      result = PIIFilter.filter(data)

      assert result.password == "[FILTERED]"
      assert result.email == ""
      assert result.name == "John"
    end
  end
end
