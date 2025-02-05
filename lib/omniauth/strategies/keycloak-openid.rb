require 'omniauth'
require 'omniauth-oauth2'
require 'json/jwt'
require 'uri'

module OmniAuth
    module Strategies
        class KeycloakOpenId < OmniAuth::Strategies::OAuth2

            class Error < RuntimeError; end
            class ConfigurationError < Error; end
            class IntegrationError < Error; end

            attr_reader :authorize_url
            attr_reader :token_url
            attr_reader :certs

            def setup_phase
                super

                if (@authorize_url.nil? || @token_url.nil?) && !OmniAuth.config.test_mode

                    prevent_site_option_mistake

                    realm = options.client_options[:realm].nil? ? options.client_id : options.client_options[:realm]
                    site = options.client_options[:site]

                    raise_on_failure = options.client_options.fetch(:raise_on_failure, false)

                    config_url = URI.join(site, "#{auth_url_base}/realms/#{realm}/.well-known/openid-configuration")

                    log :debug, "Going to get Keycloak configuration. URL: #{config_url}"
                    response = Faraday.get config_url
                    if (response.status == 200)
                        json = JSON.parse(response.body)

                        @certs_endpoint = json["jwks_uri"]
                        @userinfo_endpoint = json["userinfo_endpoint"]
                        @authorize_url = URI(json["authorization_endpoint"]).path
                        @token_url = URI(json["token_endpoint"]).path

                        log_config(json)

                        options.client_options.merge!({
                            authorize_url: @authorize_url,
                            token_url: @token_url
                                                      })
                        log :debug, "Going to get certificates. URL: #{@certs_endpoint}"
                        certs = Faraday.get @certs_endpoint
                        if (certs.status == 200)
                            json = JSON.parse(certs.body)
                            @certs = json["keys"]
                            log :debug, "Successfully got certificate. Certificate length: #{@certs.length}"
                        else
                            message = "Couldn't get certificate. URL: #{@certs_endpoint}"
                            log :error, message
                            raise IntegrationError, message if raise_on_failure
                        end
                    else
                        message = "Keycloak configuration request failed with status: #{response.status}. " \
                                  "URL: #{config_url}"
                        log :error, message
                        raise IntegrationError, message if raise_on_failure
                    end
                end
            end

            def auth_url_base
              return '/auth' unless options.client_options[:base_url]
              base_url = options.client_options[:base_url]
              return base_url if (base_url == '' || base_url[0] == '/')

              raise ConfigurationError, "Keycloak base_url option should start with '/'. Current value: #{base_url}"
            end

            def prevent_site_option_mistake
              site = options.client_options[:site]
              return unless site =~ /\/auth$/

              raise ConfigurationError, "Keycloak site parameter should not include /auth part, only domain. Current value: #{site}"
            end

            def log_config(config_json)
              log_keycloak_config = options.client_options.fetch(:log_keycloak_config, false)
              log :debug, "Successfully got Keycloak config"
              log :debug, "Keycloak config: #{config_json}" if log_keycloak_config
              log :debug, "Certs endpoint: #{@certs_endpoint}"
              log :debug, "Userinfo endpoint: #{@userinfo_endpoint}"
              log :debug, "Authorize url: #{@authorize_url}"
              log :debug, "Token url: #{@token_url}"
            end

            def build_access_token
                verifier = request.params["code"]
                cu2 = callback_url.gsub(/\?.+\Z/, "")
                Rails.logger.info "BAT1: #{callback_url}"
                Rails.logger.info "BAT2: #{cu2}"
                Rails.logger.info " TP : #{token_params}"
                Rails.logger.info "OATP: #{options.auth_token_params}"
                result = client.auth_code.get_token(verifier,
                    {:redirect_uri => callback_url.gsub(/\?.+\Z/, "")}
                    .merge(token_params.to_hash(:symbolize_keys => true)),
                    deep_symbolize(options.auth_token_params))
                Rails.logger.info "  RS: #{result.to_hash}"
                Rails.logger.info "   S: #{session.to_hash}"
                #Rails.logger.info "  RE: #{request.env}"
                result
            end

            def callback_url
                result = full_host + script_name + callback_path
                Rails.logger.info " CBU: #{result}"
                result
            end

            def authorize_params
                result = super
                Rails.logger.info "  AP: #{result.to_hash}"
                result
            end

            def callback_phase
                result = super
                Rails.logger.info " CPR: #{result}"
                result
            end

            def request_phase
                options.authorize_options.each {|key| options[key] = request.params[key.to_s] }
                super
            end

            uid{ raw_info['sub'] }

            info do
            {
                :name => raw_info['name'],
                :email => raw_info['email'],
                :first_name => raw_info['given_name'],
                :last_name => raw_info['family_name']
            }
            end

            extra do
            {
                'raw_info' => raw_info,
                'id_token' => access_token['id_token']
            }
            end

            def raw_info
                id_token_string = access_token.token
                jwks = JSON::JWK::Set.new(@certs)
                id_token = JSON::JWT.decode id_token_string, jwks
                id_token
            end

            OmniAuth.config.add_camelization('keycloak_openid', 'KeycloakOpenId')
        end
    end
end
