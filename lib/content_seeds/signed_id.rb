module ContentSeeds
  # Decodes ActiveStorage signed ids and variation tokens without the app's
  # secret. The source database is trusted, so the HMAC is never verified;
  # only the JSON envelope is parsed.
  #
  # Two envelope shapes exist in the wild:
  #
  #   * The current one (`config.load_defaults 7.2`, JSON message
  #     serializer): the payload lives directly under `_rails.data`.
  #   * The legacy one, still reachable through
  #     `config/initializers/active_storage_message_rotator.rb`: the payload
  #     is nested under `_rails.message`, itself base64. Before Rails 6.1
  #     that nested payload could be `Marshal`-dumped; those are never
  #     deserialized and decoding simply fails.
  module SignedId
    class << self
      def decode(token, purpose:)
        return nil if token.blank?

        envelope = parse_envelope(token)
        return nil unless envelope.is_a?(Hash) && envelope["pur"] == purpose.to_s

        if envelope.key?("data")
          envelope["data"]
        elsif envelope.key?("message")
          decode_legacy_message(envelope["message"])
        end
      rescue StandardError
        nil
      end

      def blob_id(token)
        Integer(decode(token, purpose: "blob_id"))
      rescue ArgumentError, TypeError
        nil
      end

      def variation(token)
        data = decode(token, purpose: "variation")
        data.is_a?(Hash) ? data : nil
      end

      private

        def parse_envelope(token)
          encoded = token.to_s.split("--", 2).first
          return nil if encoded.blank?

          JSON.parse(decode64(encoded))["_rails"]
        end

        # A legacy `message` payload that isn't valid JSON is a Rails
        # 6.1-era Marshal dump. It must never be passed to `Marshal.load`,
        # so decoding simply gives up and returns nil.
        def decode_legacy_message(message)
          JSON.parse(decode64(message.to_s))
        rescue JSON::ParserError
          nil
        end

        def decode64(string)
          Base64.decode64(string.tr("-_", "+/"))
        end
    end
  end
end
