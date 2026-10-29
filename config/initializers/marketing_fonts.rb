# frozen_string_literal: true

# Pango on macOS uses Core Text unless this is set before the first text
# render. libvips loads a font file through fontconfig, which Core Text never
# sees, so the footer would silently draw in a system font.
ENV["PANGOCAIRO_BACKEND"] = "fontconfig"
