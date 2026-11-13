# frozen_string_literal: true

module Vessel
  class Cargo
    # Class-level field type rules.
    #
    # A crawler class owns its own rule hash, which starts empty and never
    # shares storage with its ancestors or siblings. Rules are resolved at
    # Engine creation time by walking the ancestor chain, so re-registering a
    # rule while an Engine is running does not affect that Engine.
    module FieldRules
      # Registers a conversion block for one or several field names on this
      # class. Does not touch ancestors, subclasses or sibling classes.
      def field_type(*names, &block)
        names.each { |name| field_types.merge!(name.to_sym => block) }
      end

      # The rules declared directly on this class. A subclass gets its own
      # empty hash instead of a copy, so overriding a rule on a subclass can
      # never mutate the parent or a sibling.
      def field_types
        @field_types ||= {}
      end

      # Resolves the rules in effect for this class by merging the ancestor
      # chain from the base class down: closer classes win.
      def resolved_field_types
        chain = ancestors.select { |ancestor| ancestor.respond_to?(:field_types) }
        chain.reverse.inject({}) do |rules, ancestor|
          rules.merge(ancestor.field_types)
        end
      end
    end
  end
end
