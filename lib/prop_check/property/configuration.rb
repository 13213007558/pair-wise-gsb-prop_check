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
    # - `max_shrink_candidates:` The amount of shrink candidates that may be generated. (Default: 10_000)
    # - `max_consecutive_attempts:` The amount of times the library tries a filtered generator consecutively
    #    again before raising `Errors::GeneratorExhaustedError`. c.f. `PropCheck::Generator#where`. (Default: 10_000)
    # - `default_epoch:` The 'base' value to use for date/time generators like
    #    `PropCheck::Generators#date` `PropCheck::Generators#future_date` `PropCheck::Generators#time`, etc.
    #    (Default: `DateTime.now`)
    # - `resize_function:` A proc that can be used to resize _all_ generators.
    #    Takes the current size as integer and should return a new integer.
    #   (Default: `proc { |size| size }`)
    # - `failure_classifier:` An optional proc called with an exception and generated value.
    #   Shrink candidates are only accepted when their category is equal to the original failure's category.
    # - `complexity_function:` An optional proc called with a generated value. It should return a
    #   comparable complexity score; lower-scoring candidates are explored first.
    # - `candidate_key_function:` An optional proc called with a generated value. Its result is used
    #   to skip duplicate candidates while traversing a custom or cyclic shrink tree.
    Configuration = Struct.new(
      :verbose,
      :n_runs,
      :max_generate_attempts,
      :max_shrink_steps,
      :max_shrink_candidates,
      :max_consecutive_attempts,
      :default_epoch,
      :resize_function,
      :failure_classifier,
      :complexity_function,
      :candidate_key_function,
      keyword_init: true
    ) do
      def initialize(
        verbose: false,
        n_runs: 100,
        max_generate_attempts: 10_000,
        max_shrink_steps: 10_000,
        max_shrink_candidates: 10_000,
        max_consecutive_attempts: 30,
        default_epoch: DateTime.now,
        resize_function: proc { |size| size },
        failure_classifier: nil,
        complexity_function: nil,
        candidate_key_function: nil
      )
        super
      end

      def merge(other)
        Configuration.new(**to_h.merge(other.to_h))
      end
    end
  end
end
