##
# @api private
require 'pp'

module PropCheck::Property::OutputFormatter
  extend self

  def pre_output(output, n_successful, generated_root, problem)
    output.puts ""
    output.puts "(after #{n_successful} successful property test runs)"
    output.puts "Failed on: "
    output.puts "`#{print_roots(generated_root)}`"
    output.puts ""
    output.puts "Exception message:\n---\n#{problem}"
    output.puts "---"
    output.puts ""

    output
  end

  def post_output(output, n_shrink_steps, shrunken_result, shrunken_exception, shrink_status, config)
    if n_shrink_steps == 0
      output.puts 'Smallest failing input in the explored shrink tree:'
      output.puts "`#{print_roots(shrunken_result)}`"
      output.puts "Exception:\n---\n#{shrunken_exception}"
      output.puts '---'
      output.puts budget_note(shrink_status, config) if shrink_status != :complete
    else
      output.puts ''
      output.puts "Shrunken input (after #{n_shrink_steps} shrink steps, #{result_phrase(shrink_status)}):"
      output.puts "`#{print_roots(shrunken_result)}`"
      output.puts ""
      output.puts "Shrunken exception:\n---\n#{shrunken_exception}"
      output.puts "---"
      output.puts ""
      output.puts budget_note(shrink_status, config)
    end
    output
  end

  def result_phrase(shrink_status)
    return 'smallest in the explored shrink tree' if shrink_status == :complete

    'smallest found within the explored portion of the shrink tree'
  end

  def budget_note(shrink_status, config)
    case shrink_status
    when :property_budget_exhausted
      "(Note: Reached #{config.max_shrink_steps} property executions during shrinking.)"
    when :candidate_budget_exhausted
      "(Note: Reached #{config.max_shrink_candidates} generated shrink candidates; shrinking is not proven globally minimal.)"
    else
      '(shrinking impossible)'
    end
  end

  def print_roots(lazy_tree_val)
    data =
      if lazy_tree_val.is_a?(Array) && lazy_tree_val.length == 1 && lazy_tree_val[0].is_a?(Hash)
        lazy_tree_val[0]
      else
        lazy_tree_val
      end

    PP.pp(data, '')
  end
end
