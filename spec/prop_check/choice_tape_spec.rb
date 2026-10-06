# frozen_string_literal: true

RSpec.describe PropCheck::ChoiceTape do
  let(:generator) do
    PropCheck::Generators.choose(1..5).bind do |length|
      PropCheck::Generators.choose(0...length).map do |index|
        [length, index]
      end
    end
  end

  def run_failure(**config)
    PropCheck.forall(generator).with_config(**config).check do |_length, _index|
      raise 'expected failure'
    end
  rescue => e
    unless e.respond_to?(:prop_check_info) &&
           e.prop_check_info[:original_exception_message] == 'expected failure'
      raise
    end

    e
  end

  def nontrivial_token
    token = nil
    loop do
      error = run_failure(choice_tape: true, n_runs: 1)
      token = error.prop_check_info.fetch(:replay_token)
      choices = PropCheck::ReplayToken.load(token).fetch(:choices)
      break token if choices.map { |_min, _max, value| value } != [1, 0]
    end
    token
  end

  describe PropCheck::ReplayToken do
    it 'round-trips a versioned choice tape without serializing arbitrary objects' do
      tape = PropCheck::ChoiceTape.new(nil, choices: [[1, 5, 4], [0, 3, 1]], mode: :replay, size: 7)
      token = described_class.dump(tape)

      expect(token).to start_with('PCT1.')
      expect(described_class.load(token)).to eq(
        size: 7,
        choices: [[1, 5, 4], [0, 3, 1]]
      )
    end

    it 'rejects an unsupported version' do
      tape = PropCheck::ChoiceTape.new(nil, choices: [[0, 1, 0]], mode: :replay, size: 1)
      token = described_class.dump(tape)
      encoded = token.sub('PCT1.', '')
      padded = encoded + '=' * ((4 - encoded.bytesize % 4) % 4)
      payload = JSON.parse(padded.tr('-_', '+/').unpack1('m0'))
      payload['v'] = 9
      token = 'PCT1.' + [JSON.generate(payload)].pack('m0').tr('+/', '-_').delete('=')

      expect { described_class.load(token) }.to raise_error(
        PropCheck::Errors::InvalidReplayTokenError,
        /version/
      )
    end

    it 'enforces the configured encoded size' do
      choices = Array.new(100) { |index| [0, 1_000_000, index % 2] }
      tape = PropCheck::ChoiceTape.new(nil, choices: choices, mode: :replay, size: 1)

      expect { described_class.dump(tape, max_bytes: 16) }.to raise_error(
        PropCheck::Errors::ReplayTokenTooLargeError,
        /16/
      )
    end
  end

  describe 'replay' do
    it 'reproduces and shrinks the dependent bind generator after being saved in another process' do
      token = nontrivial_token
      token_path = File.join(Dir.pwd, '.tmp', 'choice_tape_token.txt')
      File.write(token_path, token)

      script = <<~RUBY
        require 'prop_check'
        generator = PropCheck::Generators.choose(1..5).bind do |length|
          PropCheck::Generators.choose(0...length).map do |index|
            [length, index]
          end
        end
        token = File.read(#{token_path.inspect}).strip
        begin
          PropCheck.forall(generator).with_config(replay_token: token).check { raise 'expected failure' }
        rescue => e
          info = e.prop_check_info
          length, index = info.fetch(:shrunken_input)
          raise 'index escaped array' unless index >= 0 && index < length

          puts info.fetch(:replay_token)
          puts info.fetch(:shrunken_input).inspect
          puts info.fetch(:shrunken_replay_token)
        end
      RUBY

      output = IO.popen(['ruby', '-Ilib', '-e', script], &:read).strip
      expect($?).to be_success

      replayed_token, shrunken_input, shrunken_token = output.lines.map(&:strip)
      expect(replayed_token).to eq(token)
      expect(shrunken_input).to eq('[1, 0]')
      expect(shrunken_token).not_to eq(token)

      shrunken_values = PropCheck::ReplayToken.load(shrunken_token).fetch(:choices).map do |_min, _max, value|
        value
      end
      shrunken_length, shrunken_index = shrunken_values
      expect(shrunken_index).to be < shrunken_length
    end

    it 'reports the first domain divergence without drawing new random choices' do
      wrong_generator = PropCheck::Generators.choose(0..3)
      token = nontrivial_token

      expect do
        PropCheck.forall(wrong_generator).with_config(replay_token: token).check { }
      end.to raise_error(
        PropCheck::Errors::ChoiceTapeMismatchError,
        /First choice tape divergence at choice 1.*expected a value from 1\.\.5.*requested 0\.\.\.4/m
      )
    end

    it 'reports when replay ends with choices still left over' do
      wrong_generator = PropCheck::Generators.choose(1..5)
      token = nontrivial_token

      expect do
        PropCheck.forall(wrong_generator).with_config(replay_token: token).check { }
      end.to raise_error(
        PropCheck::Errors::ChoiceTapeMismatchError,
        /First choice tape divergence after choice 1/
      )
    end
  end
end
