# frozen_string_literal: true

require "vessel/cargo/field"
require "vessel/cargo/field_rules"
require "vessel/cargo/field_type"
require "vessel/cargo/fields"

module Vessel
  class Cargo
    module Fieldable
      def self.included(base)
        base.extend(FieldRules)
      end

      # The field type rules in effect for this crawler instance. An Engine
      # injects a fixed snapshot when it builds the crawler; otherwise the
      # class hierarchy plus the global registry are resolved on the fly.
      attr_accessor :effective_field_types

      def effective_field_types
        @effective_field_types ||=
          self.class.resolved_field_types.merge(Cargo::FieldType.types)
      end

      def fields
        @fields ||= Fields.new
      end

      def field(name, *rest, &)
        options = rest.last.is_a?(Hash) ? rest.pop : {}
        service = options.delete(:service)
        field = Field.new(name: name, value: options[:value], context: self,
                          field_types: effective_field_types, **options, &)
        value = field.apply
        if service
          fields.service[name.to_sym] = value
        else
          fields[field.name] = value
        end
      end
    end
  end
end
