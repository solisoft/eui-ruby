# frozen_string_literal: true

require_relative '../theme'
require_relative '../proto/style'

module EUI
  module View
    # A style hash, in the spec's own vocabulary, compiled into the 64-byte
    # record the wire carries.
    #
    #     {"display" => "column", "gap" => 4, "bg" => "surface.base",
    #      "pad" => [4, 6, 4, 6], "size" => "lg", "fg" => "text.muted"}
    #
    # An unknown key is an error rather than a key that does nothing: a
    # style that is silently dropped is a page that is wrong for a day.
    class Compiler
      # `colors` is asked for a literal `#RRGGBB` and answers the session
      # table index it interned it at. Roles never reach it. `fonts` is
      # asked for a family the application bound and answers its role.
      def initialize(colors: nil, fonts: nil)
        @colors = colors
        @fonts = fonts
      end

      def record(style)
        r = Proto::StyleRecord.new
        return r if style.nil?
        raise ViewError, 'a style is a hash' unless style.is_a?(Hash)

        style.each do |key, value|
          apply(r, key.to_s, value)
        end
        r.validate!
        r
      end

      # A colour as the wire carries it: a role, a literal the session
      # interned, or nothing.
      def color(value)
        name = value.is_a?(Proto::ColorRef) ? nil : value.to_s
        return value if value.is_a?(Proto::ColorRef)
        return Proto::ColorRef::NONE if name == 'none'

        if name.start_with?('#')
          raise ViewError, "no colour table to intern '#{name}' into" unless @colors

          return Proto::ColorRef.literal(@colors.call(self.class.rgba(name)))
        end
        Proto::ColorRef.role(Theme.role(name))
      end

      # `#RRGGBB` or `#RRGGBBAA` as `0xRRGGBBAA`.
      def self.rgba(hex)
        digits = hex.delete_prefix('#')
        case digits.length
        when 6 then (Integer(digits, 16) << 8) | 0xFF
        when 8 then Integer(digits, 16)
        else raise ViewError, "a hex colour is #RRGGBB or #RRGGBBAA, got '#{hex}'"
        end
      rescue ArgumentError
        raise ViewError, "bad hex colour '#{hex}'"
      end

      private

      def apply(r, key, v)
        case key
        when 'display'      then r.display = enum(Proto::Enum::DISPLAY, v, key)
        when 'wrap'         then r.wrap = enum(Proto::Enum::WRAP, v, key)
        when 'justify'      then r.justify = enum(Proto::Enum::JUSTIFY, v, key)
        when 'align'        then r.align_items = enum(Proto::Enum::ALIGN_ITEMS, v, key)
        when 'self'         then r.align_self = enum(Proto::Enum::ALIGN_SELF, v, key)
        when 'grow'         then r.grow = byte(v, key)
        when 'shrink'       then r.shrink = byte(v, key)
        when 'gap'          then r.gap = byte(v, key)
        when 'basis'        then r.basis = dim(v)
        when 'width'        then r.width = dim(v)
        when 'height'       then r.height = dim(v)
        when 'min_width'    then r.min_width = dim(v)
        when 'min_height'   then r.min_height = dim(v)
        when 'max_width'    then r.max_width = dim(v)
        when 'max_height'   then r.max_height = dim(v)
        when 'pad'          then r.padding = edges(v)
        when 'margin'       then r.margin = edges(v)
        when 'bg'           then r.bg = color(v)
        when 'fg'           then r.fg = color(v)
        when 'border_color' then r.border_color = color(v)
        when 'border'       then r.border_width = edges(v)
        when 'radius'       then r.radius = scale(Theme::RADIUS, v, key)
        when 'shadow'       then r.shadow = scale(Theme::SHADOW, v, key)
        when 'opacity'      then r.opacity = byte(v, key)
        when 'blur'         then r.blur = byte(v, key)
        when 'font'         then r.font_family = font(v)
        when 'size'         then r.font_size = scale(Theme::TEXT, v, key)
        when 'weight'       then r.font_weight = enum(Proto::Enum::FONT_WEIGHT, v, key)
        when 'text_align'   then r.text_align = enum(Proto::Enum::TEXT_ALIGN, v, key)
        when 'clamp'        then r.line_clamp = byte(v, key)
        when 'underline'    then r.text_decoration |= (v ? 1 : 0)
        when 'strike'       then r.text_decoration |= (v ? 2 : 0)
        when 'overflow'     then r.overflow = enum(Proto::Enum::OVERFLOW, v, key)
        when 'transition'   then r.transition = enum(Proto::Enum::TRANSITION, v, key)
        when 'animation'    then r.animation = animation(v)
        when 'motion'       then r.motion = enum(Proto::Enum::MOTION, v, key)
        when 'position'     then r.position = enum(Proto::Enum::POSITION, v, key)
        when 'z'            then r.z = byte(v, key)
        when 'cursor'       then r.cursor = enum(Proto::Enum::CURSOR, v, key)
        else raise ViewError, "unknown style key '#{key}'"
        end
      end

      def enum(table, value, key)
        table.fetch(value.to_s) do
          raise ViewError, "unknown #{key} '#{value}'; it is one of #{table.keys.join(', ')}"
        end
      end

      # A scale index, written as the index or as the name the spec gives it.
      def scale(names, value, key)
        return byte(value, key) if value.is_a?(Integer)

        names.fetch(value.to_s) do
          raise ViewError, "unknown #{key} '#{value}'; it is an index or one of #{names.keys.join(', ')}"
        end
      end

      def byte(value, key)
        n = Integer(value)
        raise ViewError, "#{key} is 0–255, got #{n}" unless n.between?(0, 255)

        n
      rescue TypeError, ArgumentError
        raise ViewError, "#{key} is a number, got #{value.inspect}"
      end

      # `12` (px), `"auto"`, `"50%"`, `"1fr"`, `"sp:4"` (a space index).
      def dim(v)
        case v
        when Integer
          raise ViewError, "px is 0–65535, got #{v}" unless v.between?(0, 65_535)

          Proto::Dim.px(v)
        when Float then Proto::Dim.px(v.round.clamp(0, 65_535))
        when String, Symbol
          s = v.to_s
          if s == 'auto' then Proto::Dim.auto
          elsif s.end_with?('%') then Proto::Dim.percent((Float(s.chomp('%')) * 100).round.clamp(0, 65_535))
          elsif s.end_with?('fr') then Proto::Dim.fr((Float(s.delete_suffix('fr')) * 100).round.clamp(0, 65_535))
          elsif s.start_with?('sp:') then Proto::Dim.space(Integer(s.delete_prefix('sp:')))
          else raise ViewError, "cannot read a length from '#{s}'"
          end
        else raise ViewError, "cannot read a length from #{v.inspect}"
        end
      rescue ArgumentError
        raise ViewError, "cannot read a length from #{v.inspect}"
      end

      # One index for every side, `[y, x]`, or `[t, r, b, l]`.
      def edges(v)
        case v
        when Integer then [byte(v, 'edge')] * 4
        when Array
          case v.length
          when 4 then v.map { |n| byte(n, 'edge') }
          when 2
            y = byte(v[0], 'edge')
            x = byte(v[1], 'edge')
            [y, x, y, x]
          else raise ViewError, 'edges are one index, [y, x] or [t, r, b, l]'
          end
        else raise ViewError, "edges are one index, [y, x] or [t, r, b, l], got #{v.inspect}"
        end
      end

      # `"sans"`, `"mono"`, or a role 2..9 an application bound with a font.
      def font(v)
        case v
        when Integer
          raise ViewError, "font role #{v} is above #{Proto::Limits::MAX_FONT_ROLE}" if v > Proto::Limits::MAX_FONT_ROLE

          v
        when 'sans', :sans then 0
        when 'mono', :mono then 1
        when String, Symbol
          raise ViewError, "a font is \"sans\", \"mono\" or a family the application bound, got #{v.inspect}" unless @fonts

          @fonts.call(v.to_s)
        else raise ViewError, "a font is \"sans\", \"mono\" or a family the application bound, got #{v.inspect}"
        end
      end

      # One name, or several: a node has to say how it arrives *and* how it
      # leaves while it is still there to say it.
      def animation(v)
        Array(v).reduce(0) { |acc, name| acc | enum(Proto::Enum::ANIMATION, name, 'animation') }
      end
    end
  end
end
