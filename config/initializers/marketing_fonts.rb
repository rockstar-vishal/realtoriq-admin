# frozen_string_literal: true

# Pango on macOS uses Core Text unless this is set before the first text
# render. libvips loads a font file through fontconfig, which Core Text never
# sees, so the footer would silently draw in a system font.
ENV["PANGOCAIRO_BACKEND"] = "fontconfig"

# A web process never reuses a rendered footer. libvips otherwise keeps an
# operation cache of about 100 MB in every Puma worker.
begin
  require "vips"
  Vips.cache_set_max(0)
  Vips.cache_set_max_mem(0)
  Vips.cache_set_max_files(0)
rescue LoadError, StandardError => error
  Rails.logger.warn("vips: operation cache not limited (#{error.class})")
end
