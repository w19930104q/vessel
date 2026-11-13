# frozen_string_literal: true

require "spec_helper"

module Vessel
  describe Cargo::FieldRules do
    def crawler_class(parent = Vessel::Cargo, &block)
      Class.new(parent, &block)
    end

    describe ".field_type" do
      it "registers a rule under a symbolized name on the class" do
        block = proc { |v| v }
        klass = crawler_class { field_type("price", &block) }

        expect(klass.field_types.keys).to eq([:price])
        expect(klass.field_types[:price]).to be(block)
      end

      it "registers several names with one block" do
        block = proc { |v| v }
        klass = crawler_class { field_type(:title, :name, &block) }

        expect(klass.field_types[:title]).to be(block)
        expect(klass.field_types[:name]).to be(block)
      end
    end

    describe ".field_types" do
      it "is empty per class and not shared with the parent or siblings" do
        parent = crawler_class
        child_a = crawler_class(parent) { field_type(:price) { |v| v } }
        child_b = crawler_class(parent)

        expect(parent.field_types).to eq({})
        expect(child_b.field_types).to eq({})
        expect(child_a.field_types).not_to equal(parent.field_types)
        expect(child_a.field_types).not_to equal(child_b.field_types)
      end
    end

    describe ".resolved_field_types" do
      it "merges three inheritance levels, nearest ancestor wins" do
        grandparent = crawler_class do
          field_type(:price) { |v| "grand:#{v}" }
          field_type(:shared) { |v| "grand-shared:#{v}" }
        end
        parent = crawler_class(grandparent) do
          field_type(:shared) { |v| "parent-shared:#{v}" }
        end
        child = crawler_class(parent) do
          field_type(:price) { |v| "child:#{v}" }
        end

        resolved = child.resolved_field_types

        expect(resolved[:price].call("100")).to eq("child:100")
        expect(resolved[:shared].call("100")).to eq("parent-shared:100")
      end

      it "lets a subclass override without touching the parent or a sibling" do
        parent = crawler_class { field_type(:price) { |v| "parent:#{v}" } }
        child = crawler_class(parent) { field_type(:price) { |v| "child:#{v}" } }
        sibling = crawler_class(parent)

        expect(child.resolved_field_types[:price].call("x")).to eq("child:x")
        expect(parent.resolved_field_types[:price].call("x")).to eq("parent:x")
        expect(sibling.resolved_field_types[:price].call("x")).to eq("parent:x")
        expect(parent.field_types[:price].call("x")).to eq("parent:x")
      end

      it "falls back to global FieldType rules below every class rule" do
        global_block = proc { |v| "global:#{v}" }
        allow(Cargo::FieldType).to receive(:types).and_return(price: global_block)
        klass = crawler_class { field_type(:title) { |v| "title:#{v}" } }
        engine = Engine.new(klass)

        expect(engine.field_types[:price]).to be(global_block)
        expect(engine.field_types[:title].call("x")).to eq("title:x")
      end
    end

    describe "Engine#field_types" do
      it "is frozen at Engine creation" do
        klass = crawler_class { field_type(:price) { |v| v } }
        engine = Engine.new(klass)

        expect(engine.field_types).to be_frozen
      end

      it "prefers the single-run override over class, ancestor and global rules" do
        allow(Cargo::FieldType).to receive(:types)
          .and_return(price: proc { |v| "global:#{v}" })
        parent = crawler_class { field_type(:price) { |v| "parent:#{v}" } }
        child = crawler_class(parent) { field_type(:price) { |v| "child:#{v}" } }
        override = ->(v) { "run:#{v}" }

        engine = Engine.new(child, field_types: { price: override })

        expect(engine.field_types[:price]).to be(override)
        expect(engine.field_types[:price].call("9")).to eq("run:9")
      end

      it "keeps class rules for fields not covered by the run override" do
        parent = crawler_class { field_type(:title) { |v| "parent-title:#{v}" } }
        child = crawler_class(parent) { field_type(:price) { |v| "child-price:#{v}" } }

        engine = Engine.new(child, field_types: { price: ->(v) { "run:#{v}" } })

        expect(engine.field_types[:title].call("x")).to eq("parent-title:x")
      end

      it "does not change rules of an existing Engine when rules are re-registered" do
        klass = crawler_class { field_type(:price) { |v| "first:#{v}" } }
        engine = Engine.new(klass)

        klass.field_type(:price) { |v| "second:#{v}" }
        next_engine = Engine.new(klass)

        expect(engine.field_types[:price].call("x")).to eq("first:x")
        expect(next_engine.field_types[:price].call("x")).to eq("second:x")
      end

      it "keeps separate snapshots for parallel Engines" do
        cents = crawler_class { field_type(:price) { |v| v.to_i } }
        yuan = crawler_class { field_type(:price) { |v| v.to_f } }
        engine_cents = Engine.new(cents)
        engine_yuan = Engine.new(yuan)

        expect(engine_cents.field_types[:price].call("1099")).to eq(1099)
        expect(engine_yuan.field_types[:price].call("10.99")).to eq(10.99)
        expect(engine_cents.field_types).not_to equal(engine_yuan.field_types)
      end
    end
  end
end
