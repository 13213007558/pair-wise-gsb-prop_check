# frozen_string_literal: true

require 'open3'

RSpec.describe 'PropCheck choice tapes' do
  include PropCheck::Generators

  def dependent_index_generator
    choose(1..5).bind do |length|
      tuple(choose(0...length), constant(length))
    end
  end

  it 'records a replay token for a failing generated value' do
    expect do
      PropCheck.forall(value: choose(0..2)).with_config(choice_tape: true) do |value:|
        raise 'nope' if value > 0
      end
    end.to raise_error do |error|
      info = error.prop_check_info
      expect(info[:choice_tape_token]).to start_with('PCT1.')
      expect(error.message).to include('Original choice tape token:')
      expect(error.message).to include('Replay choice tape token:')
    end
  end

  it 'replays without drawing new random numbers' do
    captured = []

    begin
      PropCheck.forall(value: choose(0..2)).with_config(choice_tape: true, n_runs: 50) do |value:|
        captured << value
        raise 'nope' if value == 2
      end
    rescue => error
      token = error.prop_check_info[:choice_tape_token]
      replayed = nil

      expect do
        PropCheck.forall(value: choose(0..2)).replay_choice_tape(token) do |value:|
          replayed = value
          raise 'nope' if value == 2
        end
      end.to raise_error(RuntimeError, 'nope')

      expect(replayed).to eq(2)
    end
  end

  it 'reports the first range divergence during replay' do
    tape = PropCheck::ChoiceTape.new(
      mode: :replay,
      size: 1,
      entries: [[0, 1, 0], [0, 1, 0]]
    )
    token = PropCheck::ChoiceTape.encode(tape)

    expect do
      PropCheck.forall(choose(0..2)).replay_choice_tape(token) {}
    end.to raise_error(
      PropCheck::Errors::ChoiceTapeMismatchError,
      'choice #1: generator requested 0..2, but recorded range 0..1'
    )
  end

  it 'reports the first structural divergence when replay contains an extra choice' do
    tape = PropCheck::ChoiceTape.new(
      mode: :replay,
      size: 1,
      entries: [[0, 1, 0], [0, 1, 0]]
    )
    token = PropCheck::ChoiceTape.encode(tape)

    expect do
      PropCheck.forall(choose(0..1)).replay_choice_tape(token) {}
    end.to raise_error(
      PropCheck::Errors::ChoiceTapeMismatchError,
      'choice #2: generator made 1 choice(s), but the token contains 2 choice(s)'
    )
  end

  it 're-runs a dependent bind generator after shrinking the tape' do
    expect do
      PropCheck.forall(value: dependent_index_generator)
               .with_config(choice_tape: true, n_runs: 200) do |value:|
        index, length = value
        raise 'nope' if length > 3
        expect(index).to be < length
      end
    end.to raise_error do |error|
      info = error.prop_check_info
      index, length = info[:shrunken_input][:value]

      expect(length).to eq(4)
      expect(index).to be_between(0, length - 1)
      expect(info[:n_shrink_steps]).to be >= 0

      replay_index = nil
      replay_length = nil
      expect do
        PropCheck.forall(value: dependent_index_generator)
                 .replay_choice_tape(info[:choice_tape_token]) do |value:|
          replay_index, replay_length = value
          raise 'nope' if replay_length > 3
        end
      end.to raise_error(RuntimeError, 'nope')

      expect([replay_index, replay_length]).to eq([index, length])
      expect(replay_index).to be < replay_length
    end
  end

  it 'keeps shrinking later choices after an earlier choice changes the domain' do
    expect do
      PropCheck.forall(value: choose(-3..3)).with_config(choice_tape: true) do |value:|
        raise 'nope' unless value.zero?
      end
    end.to raise_error do |error|
      expect(error.prop_check_info[:shrunken_input][:value].abs).to eq(1)
    end
  end

  it 'keeps the shrunken replay failing in a fresh process' do
    script = <<~RUBY
      require 'prop_check'
      G = PropCheck::Generators
      generator = G.choose(1..5).bind do |length|
        G.tuple(G.choose(0...length), G.constant(length))
      end

      mode, token = ARGV
      if mode == 'record'
        begin
          PropCheck.forall(value: generator)
                   .with_config(choice_tape: true, n_runs: 200) do |value:|
            raise 'nope' if value.last > 3
          end
        rescue => error
          puts error.prop_check_info[:choice_tape_token]
        end
      else
        PropCheck.forall(value: generator).replay_choice_tape(token) do |value:|
          index, length = value
          raise "invalid index" unless index < length
          raise 'nope' if length > 3
        end
      end
    RUBY

    stdout, status = Open3.capture2e('ruby', '-Ilib', '-e', script, 'record')
    expect(status).to be_success
    token = stdout.strip

    stdout, status = Open3.capture2e('ruby', '-Ilib', '-e', script, 'replay', token)
    expect(status).not_to be_success
    expect(stdout).to include('nope')
    expect(stdout).not_to include('invalid index')
  end

  it 'uses a versioned restricted data format' do
    tape = PropCheck::ChoiceTape.new(mode: :replay, size: 3, entries: [[0, 2, 1]])
    token = PropCheck::ChoiceTape.encode(tape)

    expect(token).to start_with('PCT1.')
    expect(PropCheck::ChoiceTape.decode(token)).to eq(
      'v' => 1,
      'size' => 3,
      'choices' => [[0, 2, 1]]
    )

    expect do
      PropCheck::ChoiceTape.decode('PCT2.abc')
    end.to raise_error(PropCheck::Errors::ChoiceTapeTokenError, /unsupported choice tape version/)

    stub_const('PropCheck::ChoiceTape::MAX_PAYLOAD_BYTES', 32)
    expect do
      PropCheck::ChoiceTape.encode(tape)
    end.to raise_error(PropCheck::Errors::ChoiceTapeError, /too large/)
  end

  it 'rejects non-integral random choices instead of serializing them' do
    tape = PropCheck::ChoiceTape.record(1, Random.new)

    expect do
      tape.rand
    end.to raise_error(PropCheck::Errors::ChoiceTapeError, /finite integer choices/)

    expect do
      tape.rand(0.0)
    end.to raise_error(PropCheck::Errors::ChoiceTapeError, /finite integer choices/)
  end
end
