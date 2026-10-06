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
    # - `n_runs:` The amount of iterations each `forall` is being run.
    # - `max_generate_attempts:` The amount of times the library tries a generator in total
    #    before raising `Errors::GeneratorExhaustedError`. c.f. `PropCheck::Generator#where`. (Default: 10_000)
    # - `max_shrink_steps:` The amount of times shrinking is attempted. (Default: 10_000)
    # - `max_consecutive_attempts:` The amount of times the library tries a filtered generator consecutively
    #    again before raising `Errors::GeneratorExhaustedError`. c.f. `PropCheck::Generator#where`. (Default: 10_000)
    # - `coverage_confidence:` The one-sided confidence used by exact minimum-coverage declarations. (Default: 0.95)
    # - `max_coverage_runs:` Maximum successful sample budget used to establish a coverage requirement. (Default: 1_000)
    # - `default_epoch:` The 'base' value to use for date/time generators like
    #    `PropCheck::Generators#date` `PropCheck::Generators#future_date` `PropCheck::Generators#time`, etc.
    #    (Default: `DateTime.now`)
    # - `resize_function:` A proc that can be used to resize _all_ generators.
    #    Takes the current size as integer and should return a new integer.
    #   (Default: `proc { |size| size }`)
    Configuration = Struct.new(
      :verbose,
      :n_runs,
      :max_generate_attempts,
      :max_shrink_steps,
      :max_consecutive_attempts,
      :coverage_confidence,
      :max_coverage_runs,
      :default_epoch,
      :resize_function,
      keyword_init: true
    ) do
      def initialize(
        verbose: false,
        n_runs: 100,
        max_generate_attempts: 10_000,
        max_shrink_steps: 10_000,
        max_consecutive_attempts: 30,
        coverage_confidence: 0.95,
        max_coverage_runs: 1_000,
        default_epoch: DateTime.now,
        resize_function: proc { |size| size }
      )
        super
        unless n_runs.is_a?(Integer) && n_runs.positive?
          raise ArgumentError, 'n_runs must be a positive integer'
        end
        unless max_coverage_runs.is_a?(Integer) && max_coverage_runs >= n_runs
          raise ArgumentError, 'max_coverage_runs must be an integer greater than or equal to n_runs'
        end
      end

      def merge(other)
        Configuration.new(**to_h.merge(other.to_h))
      end
    end
  end
end
