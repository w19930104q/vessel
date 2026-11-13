# frozen_string_literal: true

require "spec_helper"
require "thread"

module Vessel
  describe "field type rules through the Engine" do
    # Drives the real Engine -> Cargo -> Field -> middleware path with a stub
    # request, so no browser is involved and the whole pipeline runs offline.
    # The parse logic is a proc evaluated on the crawler instance, and the
    # block Engine#handle passes to #parse yields the collected fields.
    def handle(engine, klass, data: nil, stop: true, &parse)
      klass.define_method(:parse) do |&block|
        instance_exec(&parse)
        block.call(fields)
      end
      request = Request.new(data: data)
      response = Response.new(**request.to_handler)
      engine.handle(response, request, nil)
      engine.middleware_scheduler.stop if stop
    end

    def engine_for(klass, items, field_types: nil)
      Engine.new(klass, field_types: field_types) do |hash, _fields|
        items << hash
        hash
      end
    end

    def yuan_rule
      ->(value) { value.to_s.gsub(/[^\d.]/, "").to_f }
    end

    def cents_rule
      ->(value) { value.to_s.gsub(/[^\d]/, "").to_i }
    end

    def text_rule
      ->(value) { value.to_s.strip }
    end

    def prefix_rule
      ->(value) { "p:#{value}" }
    end

    describe "three-level inheritance" do
      let(:grandparent) do
        Class.new(Cargo) do
          field_type(:price) { |v| "grand:#{v}" }
          field_type(:title) { |v| v.to_s.strip }
        end
      end
      let(:parent) do
        Class.new(grandparent) { field_type(:price) { |v| "parent:#{v}" } }
      end
      let(:child) do
        Class.new(parent) { field_type(:price) { |v| "child:#{v}" } }
      end

      it "applies the nearest rule and inherits rules from ancestors" do
        items = []
        handle(engine_for(child, items), child) do
          field :price, value: "10"
          field :title, value: "  book  "
        end

        expect(items).to contain_exactly(price: "child:10", title: "book")
      end

      it "keeps the parent behavior when the parent itself runs" do
        items = []
        handle(engine_for(parent, items), parent) do
          field :price, value: "10"
        end

        expect(items).to contain_exactly(price: "parent:10")
      end

      it "does not let a child override leak into the parent or a sibling" do
        sibling = Class.new(parent)
        items = []
        handle(engine_for(sibling, items), sibling) do
          field :price, value: "10"
        end

        expect(items).to contain_exactly(price: "parent:10")
        expect(parent.field_types[:price].call("10")).to eq("parent:10")
      end
    end

    describe "the same field name carrying different units" do
      let(:cents_site) do
        rule = cents_rule
        Class.new(Cargo) { field_type(:price, &rule) }
      end
      let(:yuan_site) do
        rule = yuan_rule
        Class.new(Cargo) { field_type(:price, &rule) }
      end

      it "converts every site with its own class rule" do
        cents_items = []
        handle(engine_for(cents_site, cents_items), cents_site) do
          field :price, value: "￥1099"
        end
        yuan_items = []
        handle(engine_for(yuan_site, yuan_items), yuan_site) do
          field :price, value: "10.99 元"
        end

        expect(cents_items).to contain_exactly(price: 1099)
        expect(yuan_items).to contain_exactly(price: 10.99)
      end

      it "lets a per-run override change one launch only" do
        override_items = []
        handle(engine_for(yuan_site, override_items,
                          field_types: { price: prefix_rule }), yuan_site) do
          field :price, value: "10.99 元"
        end
        later_items = []
        handle(engine_for(yuan_site, later_items), yuan_site) do
          field :price, value: "10.99 元"
        end

        expect(override_items).to contain_exactly(price: "p:10.99 元")
        expect(later_items).to contain_exactly(price: 10.99)
      end
    end

    describe "global registration" do
      after { Cargo::FieldType.types.delete(:global_field) }

      it "still applies through the legacy FieldType.add API" do
        Cargo::FieldType.add(:global_field, &text_rule)
        klass = Class.new(Cargo)
        items = []
        handle(engine_for(klass, items), klass) do
          field :global_field, value: "  hi  "
        end

        expect(items).to contain_exactly(global_field: "hi")
      end

      it "is overridden by the crawler class rule" do
        Cargo::FieldType.add(:global_field, &text_rule)
        rule = prefix_rule
        klass = Class.new(Cargo) { field_type(:global_field, &rule) }
        items = []
        handle(engine_for(klass, items), klass) do
          field :global_field, value: "hi"
        end

        expect(items).to contain_exactly(global_field: "p:hi")
      end
    end

    describe "re-registration while Engines are around" do
      it "keeps an existing Engine on its snapshot and switches new Engines" do
        rule = cents_rule
        klass = Class.new(Cargo) { field_type(:price, &rule) }
        first_engine = Engine.new(klass) { |h, _| h }

        klass.field_type(:price, &yuan_rule)
        second_engine = Engine.new(klass) { |h, _| h }

        first_items = []
        handle(Engine.new(klass, field_types: first_engine.field_types) do |h, _|
                 first_items << h
                 h
               end, klass) do
          field :price, value: "10.99"
        end
        second_items = []
        handle(Engine.new(klass, field_types: second_engine.field_types) do |h, _|
                 second_items << h
                 h
               end, klass) do
          field :price, value: "10.99"
        end

        expect(first_items).to contain_exactly(price: 1099)
        expect(second_items).to contain_exactly(price: 10.99)
      end
    end

    describe "a failing conversion and a later restart" do
      it "is reported by the Engine without killing it, then works on relaunch" do
        klass = Class.new(Cargo)
        attempts = Queue.new
        klass.field_type(:price) do |value|
          raise "conversion boom" if attempts.length.zero?

          value.to_i
        ensure
          attempts << :attempt
        end

        allow(Vessel::Logger).to receive(:error)
        failing_engine = Engine.new(klass) { |h, _| h }
        handle(failing_engine, klass) do
          field :price, value: "100"
        end

        expect(attempts.length).to eq(1)
        expect(Vessel::Logger).to have_received(:error).at_least(:once)

        items = []
        handle(engine_for(klass, items), klass) do
          field :price, value: "100"
        end

        expect(items).to contain_exactly(price: 100)
      end
    end

    describe "parallel Engines of the same class" do
      it "does not cross rules when runs interleave" do
        rule = cents_rule
        klass = Class.new(Cargo) { field_type(:price, &rule) }
        cents_items = []
        yuan_items = []
        cents_engine = engine_for(klass, cents_items)
        yuan_engine = engine_for(klass, yuan_items,
                                 field_types: { price: yuan_rule })
        barrier = Queue.new

        threads = [
          Thread.new do
            barrier.pop
            handle(cents_engine, klass) do
              field :price, value: "1099"
            end
          end,
          Thread.new do
            barrier.pop
            handle(yuan_engine, klass) do
              field :price, value: "10.99"
            end
          end
        ]
        2.times { barrier << :go }
        threads.each(&:join)

        expect(cents_items).to contain_exactly(price: 1099)
        expect(yuan_items).to contain_exactly(price: 10.99)
      end

      it "keeps every Engine on its own snapshot across repeated interleaved runs" do
        rule = cents_rule
        rounds = 20
        klass = Class.new(Cargo) { field_type(:price, &rule) }
        cents_items = []
        yuan_items = []
        cents_engine = engine_for(klass, cents_items)
        yuan_engine = engine_for(klass, yuan_items,
                                 field_types: { price: yuan_rule })
        start_barrier = Queue.new

        threads = [cents_engine, yuan_engine].each_with_index.map do |engine, i|
          Thread.new do
            start_barrier.pop
            rounds.times do
              handle(engine, klass, stop: false) do
                field :price, value: i.zero? ? "1099" : "10.99"
              end
            end
          end
        end
        2.times { start_barrier << :go }
        threads.each(&:join)
        cents_engine.middleware_scheduler.stop
        yuan_engine.middleware_scheduler.stop

        expect(cents_items).to all(eq(price: 1099))
        expect(yuan_items).to all(eq(price: 10.99))
        expect(cents_items.size).to eq(rounds)
        expect(yuan_items.size).to eq(rounds)
      end
    end

    describe "preserved field behavior" do
      let(:klass) do
        cents = cents_rule
        prefix = prefix_rule
        Class.new(Cargo) do
          field_type(:price, &cents)
          field_type(:writer, &prefix)
        end
      end

      it "looks rules up after rename and keeps typing:false and service fields" do
        items = []
        service_holder = []
        engine = Engine.new(klass) do |hash, fields|
          items << hash
          service_holder << fields.service
          hash
        end
        handle(engine, klass) do
          field :price, value: "￥1099"
          field :raw_price, value: " 1099 ", typing: false
          field :author, value: "ann", rename: { "author" => :writer }
          field :html, value: "<html>", service: true
        end

        expect(items).to contain_exactly(
          price: 1099, raw_price: " 1099 ", writer: "p:ann"
        )
        expect(service_holder.first).to eq(html: "<html>")
      end

      it "evaluates the conversion block in the crawler instance context" do
        contexted = Class.new(Cargo) do
          field_type(:price) { |v| "#{v}@#{data[:site]}" }
        end
        items = []
        handle(engine_for(contexted, items), contexted,
               data: { site: "shop-a" }) do
          field :price, value: "10"
        end

        expect(items).to contain_exactly(price: "10@shop-a")
      end

      it "does not change the shape of the hash sent to the middleware" do
        simple = Class.new(Cargo)
        items = []
        handle(engine_for(simple, items), simple) do
          field :name, value: "x"
          field :count, value: 3
        end

        expect(items.first.keys).to match_array(%i[name count])
      end
    end
  end
end
