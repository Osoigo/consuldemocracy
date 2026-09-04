require "content_seeds/signed_id"

module ContentSeeds
  # Rewrites the ActiveStorage editor URLs that CKEditor bakes into HTML
  # (signed with the *source* server's secret, hence useless on the target)
  # into portable `consul-seed://blob/<key>` tokens, and back.
  #
  # `consul-seed://blob/<key>` addresses a blob by its key (identical on
  # both servers). `consul-seed://blob/<key>?variant=<base64url(json)>`
  # additionally carries the variant transformations. Either form may end
  # with `disposition=attachment` when the source link was a download link.
  module Tokens
    # Editor URLs may be absolute (`http://host/rails/...`), so the optional
    # scheme + host is consumed too; otherwise it would stay glued in front
    # of the token and be re-signed into a link to the *source* host.
    # Filenames keep `'` (Journey does not escape it) but stop at quotes,
    # whitespace and angle brackets so a URL in text or an unquoted
    # attribute cannot swallow the markup that follows it.
    ORIGIN = %r{(?:https?://[^/\s"'<>]+)?}
    FILENAME = %r{[^/?"\s<>]+}
    QUERY = %r{(?:\?[^"'\s<>]*)?}

    REPRESENTATION_URL = %r{
      #{ORIGIN}/rails/active_storage/representations
      (?:/(?:redirect|proxy))?
      /(?<signed_blob_id>[^/\s"'<>]+)
      /(?<signed_variation>[^/\s"'<>]+)
      /(?<filename>#{FILENAME})
      (?<query>#{QUERY})
    }x

    BLOB_URL = %r{
      #{ORIGIN}/rails/active_storage/blobs
      (?:/(?:redirect|proxy))?
      /(?<signed_id>[^/\s"'<>]+)
      /(?<filename>#{FILENAME})
      (?<query>#{QUERY})
    }x

    TOKEN_URL = %r{
      consul-seed://blob/(?<key>[^/?&"'\s<>]+)
      (?:\?variant=(?<variant>[^&"'\s<>]+))?
      (?:[?&]disposition=(?<disposition>attachment))?
    }x

    class << self
      # Every blob id referenced by an editor URL in `html`, decodable or
      # not yet mapped to a key. Used to figure out, before any key is
      # known, which blobs must be fetched from the source database.
      def referenced_blob_ids(html)
        return [] if html.blank?

        ids = []
        html.to_s.scan(REPRESENTATION_URL) { ids << SignedId.blob_id(Regexp.last_match(:signed_blob_id)) }
        html.to_s.scan(BLOB_URL) { ids << SignedId.blob_id(Regexp.last_match(:signed_id)) }
        ids.compact.uniq
      end

      # Returns [rewritten_html, unresolved_urls]. `id_to_key` maps blob id
      # (Integer) => blob key (String). A URL whose signed id can't be
      # decoded, or whose blob id isn't in `id_to_key`, is left untouched
      # and reported in `unresolved_urls`.
      def to_tokens(html, id_to_key:)
        return [html, []] if html.blank?

        unresolved = []
        rewritten = html.to_s.gsub(REPRESENTATION_URL) do |match|
          representation_token(match, Regexp.last_match, id_to_key, unresolved)
        end
        rewritten = rewritten.gsub(BLOB_URL) do |match|
          blob_token(match, Regexp.last_match, id_to_key, unresolved)
        end

        [rewritten, unresolved]
      end

      # Returns [rewritten_html, unresolved_tokens]. Replaces
      # `consul-seed://` tokens with freshly signed paths for the blobs
      # that exist in the *target* database. An unknown key, or a variant
      # requested on a blob that isn't representable, is reported and the
      # token is either left untouched (unknown key) or replaced with a
      # plain blob path (non-variable blob).
      def from_tokens(html)
        return [html, []] if html.blank?

        unresolved = []
        rewritten = html.to_s.gsub(TOKEN_URL) { |match| blob_path(match, Regexp.last_match, unresolved) }

        [rewritten, unresolved]
      end

      private

        def representation_token(match, data, id_to_key, unresolved)
          blob_id = SignedId.blob_id(data[:signed_blob_id])
          transformations = SignedId.variation(data[:signed_variation])
          key = blob_id && id_to_key[blob_id]

          if key.nil? || transformations.nil?
            unresolved << match
            return match
          end

          token = "consul-seed://blob/#{key}?variant=#{encode_variant(transformations)}"
          append_disposition(token, data[:query])
        end

        def blob_token(match, data, id_to_key, unresolved)
          blob_id = SignedId.blob_id(data[:signed_id])
          key = blob_id && id_to_key[blob_id]

          if key.nil?
            unresolved << match
            return match
          end

          append_disposition("consul-seed://blob/#{key}", data[:query])
        end

        def blob_path(match, data, unresolved)
          blob = ::ActiveStorage::Blob.find_by(key: data[:key])

          if blob.nil?
            unresolved << match
            return match
          end

          path = blob_or_representation_path(blob, data[:variant], unresolved)
          data[:disposition] ? "#{path}?disposition=attachment" : path
        end

        def blob_or_representation_path(blob, encoded_variant, unresolved)
          return url_helpers.rails_blob_path(blob, only_path: true) if encoded_variant.nil?

          transformations = decode_variant(encoded_variant)

          if transformations.nil?
            unresolved << "undecodable variant for blob #{blob.key}"
            return url_helpers.rails_blob_path(blob, only_path: true)
          end

          unless blob.variable?
            unresolved << "blob #{blob.key} is not representable, using direct blob path"
            return url_helpers.rails_blob_path(blob, only_path: true)
          end

          variant = blob.variant(transformations.symbolize_keys)
          url_helpers.rails_representation_path(variant, only_path: true)
        end

        def encode_variant(transformations)
          Base64.urlsafe_encode64(transformations.to_json, padding: false)
        end

        def decode_variant(encoded)
          JSON.parse(Base64.urlsafe_decode64(encoded))
        rescue StandardError
          nil
        end

        def append_disposition(token, query)
          return token unless query.to_s.include?("disposition=attachment")

          token.include?("?") ? "#{token}&disposition=attachment" : "#{token}?disposition=attachment"
        end

        def url_helpers
          Rails.application.routes.url_helpers
        end
    end
  end
end
