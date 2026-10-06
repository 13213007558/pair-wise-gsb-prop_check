##
# @api private
require 'pp'

module PropCheck::Property::OutputFormatter
  extend self

  def pre_output(output, n_successful, generated_root, problem, original_choice_tape_token = nil)
    output.puts ""
    output.puts "(after #{n_successful} successful property test runs)"
    output.puts "Failed on: "
    output.puts "`#{print_roots(generated_root)}`"
    output.puts ""
    output.puts "Exception message:\n---\n#{problem}"
    output.puts "---"
    output.puts "Original choice tape token:\n`#{original_choice_tape_token}`" if original_choice_tape_token
    output.puts ""

    output
  end

  def post_output(output, n_shrink_steps, shrunken_result, shrunken_exception, shrunken_choice_tape_token = nil)
    if n_shrink_steps == 0
      output.puts '(shrinking impossible)'
    else
      output.puts ''
      output.puts "Shrunken input (after #{n_shrink_steps} shrink steps):"
      output.puts "`#{print_roots(shrunken_result)}`"
      output.puts ""
      output.puts "Shrunken exception:\n---\n#{shrunken_exception}"
      output.puts "---"
    end
    if shrunken_choice_tape_token
      output.puts "Replay choice tape token:\n`#{shrunken_choice_tape_token}`"
      output.puts ""
    end
    output
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
