# frozen_string_literal: true

module Vessel
  class Cargo
    class Field
      attr_reader :name, :value, :block, :typing

      def initialize(name:, value:, context:, rename: nil, typing: true,
                     field_types: nil, &block)
        @name = rename(name, rename)
        @value = value
        @block = block
        @context = context
        @field_types = field_types
        @typing = resolve_type if typing
      end

      def apply
        apply_block
        apply_typing
        value
      end

      private

      def apply_block
        return unless @block

        @value = @block.call
      end

      def apply_typing
        return unless typing

        @value = @context.instance_exec(value, &typing)
      end

      def rename(name, aliases)
        Hash(aliases).fetch(name.to_s, name).to_sym
      end

      def resolve_type
        types = @field_types || @context.effective_field_types
        types[@name]
      end
    end
  end
end
