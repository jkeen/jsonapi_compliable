# Responsible for parsing incoming write payloads
#
# Given a PUT payload like:
#
#   {
#     data: {
#       id: '1',
#       type: 'posts',
#       attributes: { title: 'My Title' },
#       relationships: {
#         author: {
#           data: {
#             id: '1',
#             type: 'authors'
#           }
#         }
#       }
#     },
#     included: [
#       {
#         id: '1'
#         type: 'authors',
#         attributes: { name: 'Joe Author' }
#       }
#     ]
#   }
#
# You can now easily deal with this payload:
#
#   deserializer.attributes
#   # => { id: '1', title: 'My Title' }
#   deserializer.meta
#   # => { type: 'posts', method: :update }
#   deserializer.relationships
#   # {
#   #   author: {
#   #     meta: { ... },
#   #     attributes: { ... },
#   #     relationships: { ... }
#   #   }
#   # }
#
# When creating objects, we accept a +temp-id+ so that the client can track
# the object it just created. Expect this in +meta+:
#
#   { type: 'authors', method: :create, temp_id: 'abc123' }
class JsonapiCompliable::Deserializer
  # @param payload [Hash] The incoming payload with symbolized keys
  # @param env [Hash] the Rack env (e.g. +request.env+).
  def initialize(payload, env)
    @payload = payload
    @payload = @payload[:_jsonapi] if @payload.has_key?(:_jsonapi)
    @env = env
  end

  # @return [Hash] the raw :data value of the payload
  def data
    @payload[:data]
  end

  # @return [String] the raw :id value of the payload
  def id
    data[:id] if data
  end

  # @return [Hash] the raw :attributes hash + +id+
  def attributes
    @attributes ||= raw_attributes.tap do |hash|
      hash[:id] = id if id
    end
  end

  # Override the attributes
  # # @see #attributes
  def attributes=(attrs)
    @attributes = attrs
  end

  # 'meta' information about this resource. Includes:
  #
  # +type+: the jsonapi type
  # +method+: create/update/destroy/disassociate. Based on the request env or the +method+ within the +relationships+ hash
  # +temp_id+: the +temp-id+, if specified
  #
  # @return [Hash]
  def meta
    {
      type: data[:type],
      temp_id: data[:'temp-id'],
      method: method
    }
  end

  # @return [Hash] the relationships hash
  def relationships
    @relationships ||= process_relationships(raw_relationships)
  end

  # Parses the +relationships+ recursively and builds an all-hash
  # include directive like
  #
  #   { posts: { comments: {} } }
  #
  # Relationships that have been marked for destruction will NOT
  # be part of the include directive.
  #
  # @return [Hash] the include directive
  def include_directive(memo = {}, relationship_node = nil)
    relationship_node ||= relationships

    relationship_node.each_pair do |name, relationship_payload|
      merge_include_directive(memo, name, relationship_payload)
    end

    memo
  end

  private

  def merge_include_directive(memo, name, relationship_payload)
    arrayified = [relationship_payload].flatten
    return if arrayified.all? { |rp| removed?(rp) }

    memo[name] ||= {}
    deep_merge!(memo[name], sub_directives(memo[name], arrayified))
    memo
  end

  def included
    @payload[:included] || []
  end

  def method
    case @env['REQUEST_METHOD']
      when 'POST' then :create
      when 'PUT', 'PATCH' then :update
      when 'DELETE' then :destroy
    end
  end

  def removed?(relationship_payload)
    method = relationship_payload[:meta][:method]
    [:disassociate, :destroy].include?(method)
  end

  def sub_directives(memo, relationship_payloads)
    {}.tap do |subs|
      relationship_payloads.each do |rp|
        sub_directive = include_directive(memo, rp[:relationships])
        deep_merge!(subs, sub_directive)
      end
    end
  end

  def deep_merge!(a, b)
    JsonapiCompliable::Util::Hash.deep_merge!(a, b)
  end

  def process_relationships(relationship_hash)
    {}.tap do |hash|
      relationship_hash.each_pair do |name, relationship_payload|
        name = name.to_sym

        if relationship_payload[:data]
          hash[name] = process_relationship(relationship_payload[:data])
        end
      end
    end
  end

  def process_relationship(relationship_data)
    if relationship_data.is_a?(Array)
      relationship_data.map do |rd|
        process_relationship_datum(rd)
      end
    else
      process_relationship_datum(relationship_data)
    end
  end

  def process_relationship_datum(datum)
    temp_id = datum[:'temp-id']
    included_object = included.find do |i|
      next unless i[:type] == datum[:type]

      (i[:id] && i[:id] == datum[:id]) ||
        (i[:'temp-id'] && i[:'temp-id'] == temp_id)
    end
    included_object ||= {}
    included_object[:relationships] ||= {}

    attributes = included_object[:attributes] || {}
    attributes[:id] = datum[:id] if datum[:id]
    relationships = process_relationships(included_object[:relationships] || {})
    method = datum[:method]
    method = method.to_sym if method

    {
      meta: {
        jsonapi_type: datum[:type],
        temp_id: temp_id,
        method: method
      },
      attributes: attributes,
      relationships: relationships
    }
  end

  def raw_attributes
    if data
      data[:attributes] || {}
    else
      {}
    end
  end

  def raw_relationships
    if data
      data[:relationships] || {}
    else
      {}
    end
  end
end
