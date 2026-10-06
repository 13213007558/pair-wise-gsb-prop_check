module PropCheck
  class Property
    ## Configure PropCheck
    #
    # Configurations can be set globally,
    # but also overridden on a per-generator basis.
    # c.f. PropCheck.configure, PropCheck.configuration and PropCheck::Property#with_config
    #
    # ## Available options
    # - `verbose:` When true, shows detailed options of the data generation and shrinking process. (Default: false)
    # - `choice_tape:` When true, records finite generator choices and includes a replay token after failure. (Default: false)
    # - `replay_choice_tape:` Replays the given versioned choice tape token without drawing new random numbers. (Default: nil)
    # - `n_runs:` The amount of iterations each `forall` is being run.
    # - `max_generate_attempts:` The amount of times the library tries a generator in total
    #    before raising `Errors::GeneratorExhaustedError`. c.f. `PropCheck::Generator#where`. (Default: 10_000)
    # - `max_shrink_steps:` The amount of times shrinking is attempted. (Default: 10_000)
    # - `max_consecutive_attempts:` The amount of times the library tries a filtered generator consecutively
    #    again before raising `Errors::GeneratorExhaustedError`. c.f. `PropCheck::Generator#where`. (Default: 10_000)
    # - `default_epoch:` The 'base' value to use for date/time generators like
    #    `PropCheck::Generators#date` `PropCheck::Generators#future_date` `PropCheck::Generators#time`, etc.
    #    (Default: `DateTime.now`)
    # - `resize_function:` A proc that can be used to resize _all_ generators.
    #    Takes the current size as integer and should return a new integer.
    #   (Default: `proc { |size| size }`)
    Configuration = Struct.new(
      :verbose,
      :choice_tape,
      :replay_choice_tape,
      :n_runs,
      :max_generate_attempts,
      :max_shrink_steps,
      :max_consecutive_attempts,
      :default_epoch,
      :resize_function,
      keyword_init: true
    ) do
      def initialize(
        verbose: false,
        choice_tape: false,
        replay_choice_tape: nil,
        n_runs: 100,
        max_generate_attempts: 10_000,
        max_shrink_steps: 10_000,
        max_consecutive_attempts: 30,
        default_epoch: DateTime.now,
        resize_function: proc { |size| size }
      )
        super
      end

      def merge(other)
        Configuration.new(**to_h.merge(other.to_h))
      end
    end
  end
end
