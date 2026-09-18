# frozen_string_literal: true

require_relative 'limits'
require_relative 'reader'
require_relative 'writer'

module EUI
  module Proto
    # A length, in one of the five forms the layout algorithm understands
    # (`spec/02-wire-format.md` §3.1). There is no `calc()`: a server that
    # wants a computed length computes it, and the wire carries the answer.
    Dim = Struct.new(:tag, :value) do
      AUTO    = 0
      PX      = 1
      PERCENT = 2
      FR      = 3
      SPACE   = 4

      def self.auto        = new(AUTO, 0)
      def self.px(value)   = new(PX, Integer(value))
      def self.percent(hundredths) = new(PERCENT, Integer(hundredths))
      def self.fr(hundredths)      = new(FR, Integer(hundredths))
      def self.space(index)        = new(SPACE, Integer(index))

      def self.decode(reader)
        tag = reader.u8
        value = reader.u16
        raise DecodeError, 'Dim::Auto carries a value' if tag == AUTO && value != 0
        raise DecodeError, "unknown Dim tag #{tag}" if tag > SPACE
        raise DecodeError, 'space index above 255' if tag == SPACE && value > 255

        new(tag, value)
      end

      def encode(writer)
        writer.u8(tag).u16(value)
      end
    end

    # A colour: a theme role, a literal from the session's table, or
    # nothing. Roles are strongly preferred — only a role follows the
    # viewer's mode, contrast and density.
    class ColorRef
      LITERAL_BIT = 0x8000

      attr_reader :bits

      def initialize(bits)
        @bits = bits & 0xFFFF
      end

      NONE = new(0)

      def self.role(id)       = new(id & 0x7FFF)
      def self.literal(index) = new((index & 0x7FFF) | LITERAL_BIT)

      def literal? = (@bits & LITERAL_BIT) != 0
      def none?    = @bits.zero?
      def index    = @bits & 0x7FFF

      def ==(other) = other.is_a?(ColorRef) && other.bits == @bits
      alias eql? ==
      def hash = @bits.hash
      def to_s = "ColorRef(#{literal? ? "literal #{index}" : "role #{index}"})"
    end

    # The enumerated style fields. Each one rejects a value it does not
    # define rather than clamping it: clamping is how two implementations
    # quietly disagree about a layout for a year.
    module Enum
      DISPLAY     = { 'row' => 0, 'column' => 1, 'stack' => 2, 'grid' => 3, 'none' => 4 }.freeze
      WRAP        = { 'nowrap' => 0, 'wrap' => 1, 'wrap_reverse' => 2 }.freeze
      JUSTIFY     = { 'start' => 0, 'center' => 1, 'end' => 2, 'between' => 3, 'around' => 4, 'evenly' => 5 }.freeze
      ALIGN_ITEMS = { 'start' => 0, 'center' => 1, 'end' => 2, 'stretch' => 3, 'baseline' => 4 }.freeze
      ALIGN_SELF  = ALIGN_ITEMS.merge('auto' => 5).freeze
      FONT_WEIGHT = { 'regular' => 0, 'medium' => 1, 'semibold' => 2, 'bold' => 3 }.freeze
      TEXT_ALIGN  = { 'start' => 0, 'center' => 1, 'end' => 2, 'justify' => 3 }.freeze
      OVERFLOW    = { 'visible' => 0, 'clip' => 1, 'scroll' => 2 }.freeze
      POSITION    = { 'flow' => 0, 'absolute' => 1, 'pointer' => 2 }.freeze
      CURSOR      = {
        'default' => 0, 'pointer' => 1, 'text' => 2, 'grab' => 3, 'grabbing' => 4,
        'resize_h' => 5, 'resize_v' => 6, 'wait' => 7, 'not_allowed' => 8
      }.freeze
      TRANSITION  = { 'none' => 0, 'fast' => 1, 'base' => 2, 'slow' => 3, 'slower' => 4, 'slowest' => 5 }.freeze
      MOTION      = {
        'fade' => 0, 'leading' => 1, 'trailing' => 2, 'top' => 3,
        'bottom' => 4, 'scale' => 5, 'paired' => 6
      }.freeze
      # `animation` is a bit set rather than one name: a node has to say how
      # it arrives *and* how it leaves while it is still there to say it.
      ANIMATION = { 'none' => 0, 'spin' => 1, 'enter' => 2, 'exit' => 4 }.freeze

      ANIMATION_SPIN  = 1
      ANIMATION_ENTER = 2
      ANIMATION_EXIT  = 4
      ANIMATION_MASK  = ANIMATION_SPIN | ANIMATION_ENTER | ANIMATION_EXIT

      def self.check!(table, value, what)
        raise DecodeError, "#{what} is outside the range this revision defines: #{value}" unless table.value?(value)

        value
      end
    end

    # The 64-byte computed style record (`spec/02-wire-format.md` §3).
    #
    # Everything in it is already resolved. There is no cascade, no
    # specificity, no inheritance to walk: a client's whole styling cost is
    # one indexed lookup, and a thousand table rows share three ids.
    class StyleRecord
      FIELDS = %i[
        display wrap justify align_items align_self grow shrink gap
        basis width height min_width min_height max_width max_height
        padding margin bg fg border_color border_width
        radius shadow opacity font_family font_size font_weight text_align
        line_clamp text_decoration overflow position z cursor
        transition animation blur motion
      ].freeze

      attr_accessor(*FIELDS)

      # The neutral record: a transparent row that inherits what it can.
      def initialize
        @display = 0        # row
        @wrap = 0
        @justify = 0
        @align_items = 3    # stretch
        @align_self = 5     # auto
        @grow = 0
        @shrink = 1
        @gap = 0
        @basis = Dim.auto
        @width = Dim.auto
        @height = Dim.auto
        @min_width = Dim.auto
        @min_height = Dim.auto
        @max_width = Dim.auto
        @max_height = Dim.auto
        @padding = [0, 0, 0, 0]
        @margin = [0, 0, 0, 0]
        @bg = ColorRef::NONE
        @fg = ColorRef::NONE
        @border_color = ColorRef::NONE
        @border_width = [0, 0, 0, 0]
        @radius = 0
        @shadow = 0
        @opacity = 255
        @font_family = 0    # sans
        @font_size = 2      # `base` on the text scale; 0 would be `xs`
        @font_weight = 0
        @text_align = 0
        @line_clamp = 0
        @text_decoration = 0
        @overflow = 0
        @position = 0
        @z = 0
        @cursor = 0
        @transition = 0
        @animation = 0
        @blur = 0
        @motion = 0
      end

      def self.decode(reader)
        raw = Reader.new(reader.take(Limits::STYLE_RECORD_BYTES))
        r = new
        r.display     = Enum.check!(Enum::DISPLAY, raw.u8, 'display')
        r.wrap        = Enum.check!(Enum::WRAP, raw.u8, 'wrap')
        r.justify     = Enum.check!(Enum::JUSTIFY, raw.u8, 'justify')
        r.align_items = Enum.check!(Enum::ALIGN_ITEMS, raw.u8, 'align_items')
        r.align_self  = Enum.check!(Enum::ALIGN_SELF, raw.u8, 'align_self')
        r.grow = raw.u8
        r.shrink = raw.u8
        r.gap = raw.u8
        r.basis = Dim.decode(raw)
        r.width = Dim.decode(raw)
        r.height = Dim.decode(raw)
        r.min_width = Dim.decode(raw)
        r.min_height = Dim.decode(raw)
        r.max_width = Dim.decode(raw)
        r.max_height = Dim.decode(raw)
        r.padding = raw.take(4).bytes
        r.margin = raw.take(4).bytes
        r.bg = ColorRef.new(raw.u16)
        r.fg = ColorRef.new(raw.u16)
        r.border_color = ColorRef.new(raw.u16)
        r.border_width = raw.take(4).bytes
        r.radius = raw.u8
        r.shadow = raw.u8
        r.opacity = raw.u8
        r.font_family = raw.u8
        r.font_size = raw.u8
        r.font_weight = Enum.check!(Enum::FONT_WEIGHT, raw.u8, 'font_weight')
        r.text_align  = Enum.check!(Enum::TEXT_ALIGN, raw.u8, 'text_align')
        r.line_clamp = raw.u8
        r.text_decoration = raw.u8
        r.overflow = Enum.check!(Enum::OVERFLOW, raw.u8, 'overflow')
        r.position = Enum.check!(Enum::POSITION, raw.u8, 'position')
        r.z = raw.u8
        r.cursor = Enum.check!(Enum::CURSOR, raw.u8, 'cursor')
        r.transition = raw.u8
        r.animation = raw.u8
        r.blur = raw.u8
        r.motion = Enum.check!(Enum::MOTION, raw.u8, 'motion')
        raw.finish!
        r.validate!
        r
      end

      def validate!
        raise DecodeError, 'transition is a motion index + 1, at most 5' if @transition > 5
        raise DecodeError, 'animation is a bit set of 1, 2 and 4' if (@animation & ~Enum::ANIMATION_MASK) != 0
        raise DecodeError, 'text_decoration has unknown bits' if (@text_decoration & ~0b11) != 0
        # A direction with nothing going that way.
        if @motion != 0 && (@animation & (Enum::ANIMATION_ENTER | Enum::ANIMATION_EXIT)).zero?
          raise DecodeError, 'motion needs an entrance or an exit to belong to'
        end

        self
      end

      def encode(writer)
        writer.u8(@display).u8(@wrap).u8(@justify).u8(@align_items).u8(@align_self)
        writer.u8(@grow).u8(@shrink).u8(@gap)
        [@basis, @width, @height, @min_width, @min_height, @max_width, @max_height].each { |d| d.encode(writer) }
        writer.raw(@padding.pack('C4')).raw(@margin.pack('C4'))
        writer.u16(@bg.bits).u16(@fg.bits).u16(@border_color.bits)
        writer.raw(@border_width.pack('C4'))
        writer.u8(@radius).u8(@shadow).u8(@opacity)
        writer.u8(@font_family).u8(@font_size).u8(@font_weight).u8(@text_align)
        writer.u8(@line_clamp).u8(@text_decoration).u8(@overflow).u8(@position).u8(@z).u8(@cursor)
        writer.u8(@transition).u8(@animation).u8(@blur).u8(@motion)
        writer
      end

      def to_bytes
        w = Writer.new
        encode(w)
        w.to_s
      end

      def ==(other)
        other.is_a?(StyleRecord) && other.to_bytes == to_bytes
      end
      alias eql? ==

      def hash = to_bytes.hash
    end
  end
end
