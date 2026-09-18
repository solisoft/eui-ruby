# frozen_string_literal: true

require_relative 'dsl'
require_relative 'errors'

module EUI
  # One component: state, handlers, and a view that is a function of the
  # state.
  #
  #     class Counter < EUI::Component
  #       def mount(_params) = @count = 0
  #
  #       on "increment" { @count += 1 }
  #
  #       def render
  #         column(gap: 4, pad: 8) do
  #           [text(@count.to_s, size: "4xl"), button("+", "increment")]
  #         end
  #       end
  #     end
  #
  # A handler changes state and returns; it never touches the tree. What
  # reaches the client is the *difference* the change made, which is the
  # one thing this protocol is for.
  class Component
    include DSL

    class << self
      def handlers
        @handlers ||= superclass.respond_to?(:handlers) ? superclass.handlers.dup : {}
      end

      # Name an event this component answers. The name is the one the view
      # put on a node, not the event kind: `{"on" => {"wake" => "tick"}}`
      # arrives here as `tick`.
      def on(name, &block)
        handlers[name.to_s] = block
        self
      end

      def handler_for(name) = handlers[name.to_s]
    end

    attr_reader :session, :viewport

    def initialize(session: nil)
      @session = session
      @viewport = {}
    end

    # Called once, when the socket has said Hello. `params["viewport"]` is
    # the window as it is right now; a `viewport` event follows every
    # resize, so nothing has to ask.
    def mount(params)
      @viewport = params['viewport'] || {}
    end

    # Called when the session ends, for whatever reason.
    def unmount; end

    # The view: a hash, and a pure function of the state. It is called
    # after every handler, so it must be cheap and must not have effects.
    def render
      raise NotImplementedError, "#{self.class} has no render"
    end

    # Dispatch. A block registered with `on` wins; otherwise a public
    # method of the same name; otherwise the event is dropped with a line
    # in the log, because a view naming a handler nobody wrote is a typo
    # and not a reason to end somebody's session.
    def handle(name, params)
      @viewport = params['viewport'] if name == 'viewport' && params['viewport']

      block = self.class.handler_for(name)
      return instance_exec(params, &block) if block

      method_name = name.to_sym
      return public_send(method_name, params) if respond_to?(method_name) && method(method_name).arity != 0
      return public_send(method_name) if respond_to?(method_name)
      return if name == 'viewport'

      raise Error, "no handler for '#{name}'"
    end

    # Render again although nothing arrived: a timer, a message from
    # another session, anything this process knows and the client does not.
    def refresh! = @session&.refresh!

    def notify(title, body: '', tag: '') = @session&.notify(title, body: body, tag: tag)

    def close(reason = 'the application closed the session') = @session&.close(reason)

    # Whether the person granted this application something it asked for.
    # Being granted is a separate act from asking, and this is the only
    # place the answer shows up.
    def granted?(capability) = @session ? @session.granted?(capability) : false

    # The window, in device-independent pixels. Every width worth having is
    # derived from it: a fixed one is what reads as unfinished on somebody
    # else's screen.
    def width  = @viewport['width'].to_i
    def height = @viewport['height'].to_i
    def dark?  = @viewport['mode'] == 'dark'
  end
end
