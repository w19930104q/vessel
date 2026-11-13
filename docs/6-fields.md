---
sidebar_position: 6
---

# Fields

Instead of building a hash by hand a handler can declare fields and yield the
collected `fields` object.

#### field(name, \*\*options, &block)

* options `Hash`
  * :value `Object` value of the field
  * :service `Boolean` keeps the field out of the resulting hash, it's only
    available as `fields.service[:name]` in the
    [middleware](/docs/vessel/middleware)
  * :rename `Hash` stores the field under another name, e.g.
    `{ "author" => :writer }`
  * :typing `Boolean` `false` skips the [field type](#field-types)
* block - called instead of `value` when it's given

#### fields : `Vessel::Cargo::Fields`

Fields collected in the handler, `fields.to_h` returns them as a `Hash`.

```ruby
class MyScraper < Vessel::Cargo
  def parse
    field :author, value: at_xpath("span/small").text
    field :text, value: at_css("span.text").text
    field :html, value: nil, service: true do
      raw
    end

    yield fields
  end
end
```

The middleware gets `{ author: ..., text: ... }` as the hash and the fields
object with `fields.service[:html]`.

## Field types

Fields can be normalized in one place by their name. Put such declarations into
`config/fields` of a [generated project](/docs/vessel/projects-cli):

```ruby
Vessel::Cargo::FieldType.add(:price) { |value| value.to_s.gsub(/[^\d.]/, "").to_f }
Vessel::Cargo::FieldType.add(:title, :name) { |value| value.to_s.strip }
```

Every `field :price` is then passed through that block, `typing: false` skips
it. The type is looked up by the final name, after `rename`. The block is
evaluated in the crawler instance, so `url`, `data` and the selectors are
available in it.

### Class rules

Global rules apply to every crawler, but the same field name can mean
different things on different sites - a price in cents on one shop and a
decimal amount with a currency label on another. Declare a rule directly on a
crawler class with `field_type`:

```ruby
class CentsShop < Vessel::Cargo
  field_type :price do |value|
    value.to_s.gsub(/[^\d]/, "").to_i
  end

  def parse
    field :price, value: at_css(".price").text # "￥1099" -> 1099
    yield fields
  end
end

class YuanShop < Vessel::Cargo
  field_type :price do |value|
    value.to_s.gsub(/[^\d.]/, "").to_f
  end

  def parse
    field :price, value: at_css(".price").text # "10.99 元" -> 10.99
    yield fields
  end
end
```

A subclass inherits the rules of its ancestors and may override any of them;
the override stays on that subclass, the parent and sibling classes keep their
own rules. Resolution order for a field name is:

1. rules passed to this single run
2. rules declared on the crawler class
3. rules declared on its nearest ancestor, up the chain
4. the global `Vessel::Cargo::FieldType` registry

### Per-run overrides

Rules can be swapped for one launch without touching the class, through
`Cargo.run` or directly on the Engine:

```ruby
YuanShop.run(field_types: { price: ->(value) { value.to_s } })

engine = Vessel::Engine.new(YuanShop,
                            field_types: { price: ->(value) { value.to_s } })
```

An Engine snapshots the effective rules when it is created. Re-registering a
rule while it runs does not change that Engine; Engines created afterwards
pick the new rules up, and several Engines running in parallel keep their own
snapshots even when they crawl the same class.
