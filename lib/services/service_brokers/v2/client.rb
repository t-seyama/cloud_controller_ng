module VCAP::Services::ServiceBrokers::V2
  class ServiceBrokerBadResponse < HttpResponseError
    def initialize(uri, method, response)
      begin
        hash = MultiJson.load(response.body)
      rescue MultiJson::ParseError
      end

      if hash.is_a?(Hash) && hash.has_key?('description')
        message = "Service broker error: #{hash['description']}"
      else
        message = "The service broker API returned an error from #{uri}: #{response.code} #{response.message}"
      end

      super(message, uri, method, response)
    end

    def response_code
      502
    end
  end

  class ServiceBrokerResponseMalformed < HttpResponseError
    def initialize(uri, method, response)
      super(
        "The service broker response was not understood",
        uri,
        method,
        response
      )
    end
  end

  class ServiceBrokerApiAuthenticationFailed < HttpResponseError
    def initialize(uri, method, response)
      super(
        "Authentication failed for the service broker API. Double-check that the username and password are correct: #{uri}",
        uri,
        method,
        response
      )
    end

    def response_code
      502
    end
  end

  class ServiceBrokerConflict < HttpResponseError
    def initialize(uri, method, response)
      error_message = nil
      if parsed_json(response.body).has_key?('message')
        error_message = parsed_json(response.body)["message"]
      else
        error_message = parsed_json(response.body)["description"]
      end

      super(
        error_message || "Resource conflict: #{uri}",
        uri,
        method,
        response
      )
    end

    def response_code
      409
    end

    private

    def parsed_json(str)
      MultiJson.load(str)
    rescue MultiJson::ParseError
      {}
    end
  end

  class Client

    CATALOG_PATH = '/v2/catalog'.freeze

    def initialize(attrs)
      @http_client = VCAP::Services::ServiceBrokers::V2::HttpClient.new(attrs)
      @attrs = attrs
    end

    def catalog
      response = @http_client.get(CATALOG_PATH)
      parse_response(:get, CATALOG_PATH, response)
    end

    # The broker is expected to guarantee uniqueness of instance_id.
    # raises ServiceBrokerConflict if the id is already in use
    def provision(instance)
      path = "/v2/service_instances/#{instance.guid}"

      response = @http_client.put(path, {
        service_id:        instance.service.broker_provided_id,
        plan_id:           instance.service_plan.broker_provided_id,
        organization_guid: instance.organization.guid,
        space_guid:        instance.space.guid,
      })

      parsed_response = parse_response(:put, path, response)
      instance.dashboard_url = parsed_response['dashboard_url']

      # DEPRECATED, but needed because of not null constraint
      instance.credentials = {}

    rescue ServiceBrokerApiTimeout, ServiceBrokerBadResponse => e
      VCAP::CloudController::ServiceBrokers::V2::ServiceInstanceDeprovisioner.deprovision(@attrs, instance)
      raise e
    end

    def bind(binding)
      path = "/v2/service_instances/#{binding.service_instance.guid}/service_bindings/#{binding.guid}"
      response = @http_client.put(path, {
        service_id:  binding.service.broker_provided_id,
        plan_id:     binding.service_plan.broker_provided_id,
        app_guid:    binding.app_guid
      })
      parsed_response = parse_response(:put, path, response)

      binding.credentials = parsed_response['credentials']
      if parsed_response.has_key?('syslog_drain_url')
        binding.syslog_drain_url = parsed_response['syslog_drain_url']
      end

    rescue ServiceBrokerApiTimeout, ServiceBrokerBadResponse => e
      VCAP::CloudController::ServiceBrokers::V2::ServiceInstanceUnbinder.unbind(@attrs, binding)
      raise e
    end

    def unbind(binding)
      path = "/v2/service_instances/#{binding.service_instance.guid}/service_bindings/#{binding.guid}"

      response = @http_client.delete(path, {
        service_id: binding.service.broker_provided_id,
        plan_id:    binding.service_plan.broker_provided_id,
      })

      parse_response(:delete, path, response)
    end

    def deprovision(instance)
      path = "/v2/service_instances/#{instance.guid}"

      response = @http_client.delete(path, {
        service_id: instance.service.broker_provided_id,
        plan_id:    instance.service_plan.broker_provided_id,
      })

      parse_response(:delete, path, response)

    rescue VCAP::Services::ServiceBrokers::V2::ServiceBrokerConflict => e
      raise VCAP::Errors::ApiError.new_from_details("ServiceInstanceDeprovisionFailed", e.message)
    end

    def update_service_plan(instance, plan)
      path = "/v2/service_instances/#{instance.guid}/"

      response = @http_client.patch(path, {
          plan_id:	plan.broker_provided_id,
          previous_values: {
            plan_id: instance.service_plan.broker_provided_id,
            service_id: instance.service.broker_provided_id,
            organization_id: instance.organization.guid,
            space_id: instance.space.guid
          }
      })

      parse_response(:put, path, response)
    end

    private

    def uri_for(path)
      URI(@http_client.url + path)
    end

    def parse_response(method, path, response)
      uri = uri_for(path)
      code = response.code.to_i

      case code
        when 204
          return nil # no body

        when 200..299

          begin
            response_hash = MultiJson.load(response.body)
          rescue MultiJson::ParseError
            logger.warn("MultiJson parse error `#{response.try(:body).inspect}'")
          end

          unless response_hash.is_a?(Hash)
            raise VCAP::Services::ServiceBrokers::V2::ServiceBrokerResponseMalformed.new(uri.to_s, method, response)
          end

          return response_hash

        when HTTP::Status::UNAUTHORIZED
          raise VCAP::Services::ServiceBrokers::V2::ServiceBrokerApiAuthenticationFailed.new(uri.to_s, method, response)

        when 408
          raise VCAP::Services::ServiceBrokers::V2::ServiceBrokerApiTimeout.new(uri.to_s, method, response)

        when 409
          raise VCAP::Services::ServiceBrokers::V2::ServiceBrokerConflict.new(uri.to_s, method, response)

        when 410
          if method == :delete
            logger.warn("Already deleted: #{uri.to_s}")
            return nil
          end
      end

      raise VCAP::Services::ServiceBrokers::V2::ServiceBrokerBadResponse.new(uri.to_s, method, response)
    end

    def logger
      @logger ||= Steno.logger('cc.service_broker.v2.client')
    end
  end
end
