module JsonapiCompliable
  class ResourceRequest
    attr_accessor :resource, :scope, :selection

    def initialize(context, opts = {})
      @context  = context
      @selection = opts[:scope]
      self
    end

    def response(args = {})
      opts  = default_jsonapi_render_options.merge(args)
      opts  = Util::RenderOptions.generate(@selection, query_hash, opts)
      opts[:expose][:context] = @context

      if opts[:include].empty? && force_includes?
        opts[:include] = include_directive
      end

      JSONAPI::Serializable::Renderer.new.render(opts.delete(:jsonapi), opts).to_json
    end

    def found?
      @selection.present?
    end

    def model
      resource.try(:model)
    end

    def resource
      @resource ||= begin
        resource = @context.class._jsonapi_compliable
        if resource.is_a?(Hash)
          resource[action_name.to_sym].new
        else
          resource.new
        end
      end
    end

    def save
      resource.transaction do
        JsonapiCompliable::Util::Hooks.record do
          begin
            @selection = resource.persist_with_relationships(
              deserialized_params.meta,
              deserialized_params.attributes,
              deserialized_params.relationships
            )
          rescue ActiveRecord::RecordNotFound => e
            @error = {
              "status": "not_found",
              "code": "404",
              "title": "related resource not found",
              "details": e.message
            }
          end
        end
      end

      validate.errors.empty? && @error.nil?
    end

    def status
      # TODO return json-api standard status code of performed transaction.
    end

    def location
      # TODO return location of processed resource
    end

    def update(args)
      resource.transaction do
        JsonapiCompliable::Util::Hooks.record do
          begin
            @selection = resource.persist_with_relationships(
              deserialized_params.meta,
              deserialized_params.attributes,
              deserialized_params.relationships
            )
          rescue ActiveRecord::RecordNotFound => e
            @error = {
              "status": "not_found",
              "code": "404",
              "title": "related resource not found",
              "details": e.message
            }
          end
        end
      end

      validate.errors.empty? && @error.nil?
    end

    def validate
      validation = JsonapiErrorable::Serializers::Validation.new(@selection, @context.deserialized_params.relationships)
    end

    def errors
      if @error
        return { errors: [@error]}
      elsif not self.found?
        return { errors: [
          {
            "status": "not_found",
            "code": "404",
            "title": "resource not found",
            "details": "#{resource.model.to_s} not found"
          }
        ]}
      else
        return { errors: validate.errors }
      end
    end

    private

    def action_name
      @context.action_name
    end

    def deserialized_params
      @context.deserialized_params
    end

    def default_jsonapi_render_options
      @context.default_jsonapi_render_options
    end

    def query_hash
      @context.query_hash
    end

    def include_directive
      @context.deserialized_params.include_directive
    end

    def force_includes?
      not @context.deserialized_params.data.nil?
    end
  end
end
