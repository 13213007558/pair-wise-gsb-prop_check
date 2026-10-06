# frozen_string_literal: true

require 'json'

module PropCheck
  class ReplayToken
    VERSION = 1
    PREFIX = "PCT#{VERSION}."

    def self.dump(tape, max_bytes: 4096)
      new(max_bytes: max_bytes).dump(tape)
    end

    def self.load(token, max_bytes: 4096)
      new(max_bytes: max_bytes).load(token)
    end

    def initialize(max_bytes: 4096)
      @max_bytes = max_bytes
    end

    def dump(tape)
      size = tape.size
      unless size.is_a?(Integer) && size >= 1
        raise ArgumentError, 'replay token size must be a positive integer'
      end

      payload = {
        'v' => VERSION,
        's' => size,
        'c' => tape.logged_choices.map(&:to_a)
      }
      encoded = [JSON.generate(payload)].pack('m0').tr('+/', '-_').delete('=')
      token = PREFIX + encoded

      ensure_within_limit!(token)
      token
    end

    def load(token)
      unless token.is_a?(String) && token.start_with?(PREFIX)
        raise invalid_token('it must begin with PCT1.')
      end

      ensure_within_limit!(token)
      encoded = token[PREFIX.length..-1]
      payload = decode_payload(encoded)
      validate_payload!(payload)

      {
        size: payload.fetch('s'),
        choices: payload.fetch('c').map { |choice| choice.map { |value| Integer(value) } }
      }
    end

    private

    def ensure_within_limit!(token)
      return if token.bytesize <= @max_bytes

      message =
        "replay token is #{token.bytesize} bytes but configured limit is #{@max_bytes}. " +
        'Increase max_replay_token_bytes or simplify the failing generator.'
      raise Errors::ReplayTokenTooLargeError, message
    end

    def decode_payload(encoded)
      raise invalid_token('its encoded payload is empty') if encoded.empty?

      padded = encoded + '=' * ((4 - encoded.bytesize % 4) % 4)
      JSON.parse(padded.tr('-_', '+/').unpack1('m0'))
    rescue ArgumentError, JSON::ParserError
      raise invalid_token('its encoded payload is not valid Base64-encoded JSON')
    end

    def validate_payload!(payload)
      unless payload.is_a?(Hash)
        raise invalid_token('its decoded payload must be a JSON object')
      end

      unless payload.keys.sort == %w[c s v]
        raise invalid_token('its payload must contain exactly keys v, s, and c')
      end

      version = payload.fetch('v')
      unless version == VERSION
        raise invalid_token("its version is #{version.inspect}, but this library supports version #{VERSION}")
      end

      size = payload.fetch('s')
      unless size.is_a?(Integer) && size >= 1
        raise invalid_token('its size must be a positive integer')
      end

      choices = payload.fetch('c')
      unless choices.is_a?(Array)
        raise invalid_token('its choice list must be an array')
      end

      choices.each_with_index do |choice, index|
        validate_choice!(choice, index)
      end
    end

    def validate_choice!(choice, index)
      unless choice.is_a?(Array) && choice.length == 3 && choice.all? { |value| value.is_a?(Integer) }
        raise invalid_token("choice #{index + 1} must be an array of exactly three integers")
      end

      min, max, value = choice
      if min > max
        raise invalid_token("choice #{index + 1} has a minimum greater than its maximum")
      end
      unless value >= min && value <= max
        raise invalid_token("choice #{index + 1} has a value outside its range")
      end
    end

    def invalid_token(message)
      Errors::InvalidReplayTokenError.new("Invalid replay token: #{message}")
    end
  end
end
