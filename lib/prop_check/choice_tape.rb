# frozen_string_literal: true

require 'json'

module PropCheck
  class ChoiceTape
    VERSION = 1
    MAX_ENTRIES = 10_000
    MAX_PAYLOAD_BYTES = 65_536
    TOKEN_PREFIX = "PCT#{VERSION}."

    attr_reader :mode, :size, :entries

    def initialize(mode:, size:, entries: [], rng: nil)
      @mode = mode
      @size = size
      @entries = entries
      @rng = rng
      @position = 0
    end

    def self.record(size, rng)
      new(mode: :record, size: size, rng: rng)
    end

    def self.replay(payload)
      new(mode: :replay, size: payload.fetch('size'), entries: payload.fetch('choices').map(&:dup))
    end

    def self.adapt(payload)
      new(mode: :shrink, size: payload.fetch('size'), entries: payload.fetch('choices').map(&:dup))
    end

    def self.encode(tape)
      payload = {
        'v' => VERSION,
        'size' => tape.size,
        'choices' => tape.entries.map(&:dup)
      }

      validate_payload!(payload)
      json = JSON.generate(payload)
      if json.bytesize > MAX_PAYLOAD_BYTES
        raise Errors::ChoiceTapeError, "choice tape payload is too large (#{json.bytesize} bytes)"
      end

      TOKEN_PREFIX + [json].pack('m0').tr('+/', '-_').delete('=')
    end

    def self.decode(token)
      raise Errors::ChoiceTapeTokenError, 'choice tape token must be a string' unless token.is_a?(String)
      prefix, encoded = token.split('.', 2)
      unless prefix =~ /\APCT[0-9]+\z/ && encoded
        raise Errors::ChoiceTapeTokenError, 'unsupported or missing choice tape token version'
      end
      unless prefix == "PCT#{VERSION}"
        raise Errors::ChoiceTapeTokenError, "unsupported choice tape version: #{prefix.delete_prefix('PCT').inspect}"
      end

      padded = encoded + '=' * ((4 - encoded.length % 4) % 4)
      json = padded.tr('-_', '+/').unpack1('m0')
      payload = JSON.parse(json)
      validate_payload!(payload)
      payload
    rescue ArgumentError, JSON::ParserError, TypeError
      raise Errors::ChoiceTapeTokenError, 'choice tape token is not valid base64-encoded JSON'
    end

    def self.validate_payload!(payload)
      unless payload.is_a?(Hash) && payload.keys.sort == %w[choices size v]
        raise Errors::ChoiceTapeTokenError, 'choice tape token has invalid fields'
      end
      unless payload['v'] == VERSION
        raise Errors::ChoiceTapeTokenError, "unsupported choice tape version: #{payload['v'].inspect}"
      end
      unless payload['size'].is_a?(Integer) && payload['size'] >= 0
        raise Errors::ChoiceTapeTokenError, 'choice tape size must be a nonnegative integer'
      end
      unless payload['choices'].is_a?(Array) && payload['choices'].length <= MAX_ENTRIES
        raise Errors::ChoiceTapeTokenError, "choice tape can contain at most #{MAX_ENTRIES} choices"
      end

      payload['choices'].each_with_index do |entry, index|
        unless entry.is_a?(Array) && entry.length == 3 && entry.all? { |value| value.is_a?(Integer) }
          raise Errors::ChoiceTapeTokenError, "choice ##{index + 1} must contain [minimum, maximum, value] integers"
        end

        min, max, value = entry
        unless min <= max && value >= min && value <= max
          raise Errors::ChoiceTapeTokenError, "choice ##{index + 1} has an invalid range or value"
        end
      end
    end

    def rand(range_or_max = nil, deprecated_max = nil)
      min, max = normalize_choice(range_or_max, deprecated_max)
      append_choice(min, max)
    end

    def finish!
      case @mode
      when :replay
        if @entries.length > @position
          raise Errors::ChoiceTapeMismatchError,
                "choice ##{@position + 1}: generator made #{@position} choice(s), but the token contains #{@entries.length} choice(s)"
        end
      when :shrink
        @entries = @entries.first(@position)
      end

      self
    end

    private def append_choice(min, max)
      number = @position
      if number >= MAX_ENTRIES
        raise Errors::ChoiceTapeError, "choice tape can contain at most #{MAX_ENTRIES} choices"
      end

      case @mode
      when :record
        value = @rng.rand(min..max)
        @entries << [min, max, value]
      when :replay
        recorded = @entries[number]
        raise mismatch(number, min, max, nil) if recorded.nil?

        recorded_min, recorded_max, value = recorded
        if recorded_min != min || recorded_max != max
          raise mismatch(number, min, max, recorded)
        end
      when :shrink
        recorded = @entries[number]
        if recorded.nil?
          value = min
          @entries << [min, max, value]
        else
          _recorded_min, _recorded_max, candidate_value = recorded
          value =
            if candidate_value >= min && candidate_value <= max
              candidate_value
            else
              [[candidate_value, min].max, max].min
            end
          @entries[number] = [min, max, value]
        end
      end

      @position = number + 1
      value
    end

    private def normalize_choice(range_or_max, deprecated_max)
      if !deprecated_max.nil? && !(range_or_max.is_a?(Integer) && deprecated_max.is_a?(Integer))
        raise Errors::ChoiceTapeError, 'choice tape only supports finite integer choices'
      end

      if deprecated_max.nil? && range_or_max.is_a?(Numeric) && !range_or_max.is_a?(Integer)
        raise Errors::ChoiceTapeError, 'choice tape only supports finite integer choices'
      end

      if !deprecated_max.nil?
        min = range_or_max
        max = deprecated_max - 1
        raise Errors::ChoiceTapeError, "choice range #{min}...#{deprecated_max} is empty" if min > max

        [min, max]
      elsif range_or_max.is_a?(Integer)
        raise Errors::ChoiceTapeError, 'choice tape only supports positive integer bounds' unless range_or_max.positive?

        [0, range_or_max - 1]
      elsif range_or_max.is_a?(Range) && range_or_max.begin.is_a?(Integer) && range_or_max.end.is_a?(Integer)
        min = range_or_max.begin
        max = range_or_max.end
        max -= 1 if range_or_max.exclude_end?
        raise Errors::ChoiceTapeError, "choice range #{range_or_max.inspect} is empty" if min > max

        [min, max]
      else
        raise Errors::ChoiceTapeError, 'choice tape only supports finite integer choices'
      end
    end

    private def mismatch(number, min, max, recorded)
      expected = recorded.nil? ? 'no choice was recorded' : "recorded range #{recorded[0]}..#{recorded[1]}"
      Errors::ChoiceTapeMismatchError.new(
        "choice ##{number + 1}: generator requested #{min}..#{max}, but #{expected}"
      )
    end
  end
end
