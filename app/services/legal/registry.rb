# frozen_string_literal: true

module Legal
  # The published texts. The file hash is checked against the pin on load, so a
  # hand-edited markdown file cannot be served as if it were the signed version.
  class Registry
    Document = Data.define(:kind, :version, :path, :sha256, :text)
    ROOT = Rails.root.join("config/legal")

    class << self
      def current(kind)
        entries(kind).last || raise("No published #{kind}")
      end

      def find(kind, version)
        entries(kind).find { |document| document.version == version.to_s } ||
          raise(ActiveRecord::RecordNotFound, "No #{kind} version #{version}")
      end

      def entries(kind)
        cache[kind.to_s] ||= load_entries(kind)
      end

      private

      def cache
        @cache ||= {}
      end

      def load_entries(kind)
        listed = YAML.safe_load_file(ROOT.join("registry.yml")).fetch(kind.to_s)
        listed.map { |row| load_document(kind, row) }
      end

      def load_document(kind, row)
        path = ROOT.join(row.fetch("file"))
        digest = Digest::SHA256.file(path).hexdigest
        raise "Legal file #{row['file']} does not match its pin" if digest != row.fetch("sha256")

        Document.new(
          kind: kind.to_s,
          version: row.fetch("version"),
          path: path.to_s,
          sha256: digest,
          text: path.read
        )
      end
    end
  end
end
