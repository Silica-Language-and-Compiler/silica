#!/usr/bin/env bash

# Usage:
#   ./find_do_done_end.sh /path/to/search
#
# Finds do/done...end occurrences in .silica files.
#
# Reports:
#   - every do/done...end occurrence with line numbers
#   - total number of occurrences
#   - number of occurrences that appear to be on the right side of a case arm
#     inside a case ... of { ... } construct

set -euo pipefail

DIR="${1:-.}"

total_count=0
case_arm_right_count=0

while IFS= read -r -d '' file; do
  while IFS=$'\t' read -r location is_case_arm_right; do
    echo "$location"

    total_count=$((total_count + 1))

    if [[ "$is_case_arm_right" == "1" ]]; then
      case_arm_right_count=$((case_arm_right_count + 1))
    fi
  done < <(
    perl -0777 -ne '
      sub line_number_at {
        my ($text, $pos) = @_;
        return 1 + (substr($text, 0, $pos) =~ tr/\n//);
      }

      sub is_inside_case_arm {
        my ($text, $do_pos) = @_;

        # Find the nearest preceding case ... of { before this do/done.
        # This is still a lightweight scanner, not a full parser.
        my $prefix = substr($text, 0, $do_pos);

        my $case_start = -1;
        my $case_open_brace = -1;

        while ($prefix =~ /\bcase\b.*?\bof\b\s*\{/sg) {
          $case_start = $-[0];
          $case_open_brace = $+[0] - 1;
        }

        return 0 if $case_start < 0;

        # Starting at the { after "case ... of", scan forward to see whether
        # the do/done position is still inside that brace block.
        my $depth = 0;
        my $inside_case_body = 0;

        for (my $i = $case_open_brace; $i < $do_pos; $i++) {
          my $ch = substr($text, $i, 1);

          if ($ch eq "{") {
            $depth++;
            $inside_case_body = 1;
          }
          elsif ($ch eq "}") {
            $depth--;
            return 0 if $inside_case_body && $depth <= 0;
          }
        }

        return 0 unless $inside_case_body && $depth > 0;

        # Now check whether there is a case-arm arrow between the case body
        # opening brace and this do/done.
        my $case_body_before_do =
          substr($text, $case_open_brace + 1, $do_pos - $case_open_brace - 1);

        my $last_arrow = rindex($case_body_before_do, "->");
        return 0 if $last_arrow < 0;

        # Check that the do/done is on the right side of that arrow.
        # This supports both:
        #
        #   Pattern -> do ... end
        #
        # and:
        #
        #   Pattern ->
        #     do ... end
        #
        my $after_arrow = substr($case_body_before_do, $last_arrow + 2);

        # If another arm separator-like line appears after the arrow before
        # the do/done, this may be a different arm. This is conservative.
        return 0 if $after_arrow =~ /^\s*[^{}\n]+->/m;

        return 1;
      }

      while (/\bdo(?:ne)?\b.*?\bend\b/sg) {
        my $match_start = $-[0];
        my $match_end   = $+[0];

        my $start_line = line_number_at($_, $match_start);
        my $end_line   = line_number_at($_, $match_end);

        my $is_case_arm_right = is_inside_case_arm($_, $match_start);

        print "$ARGV:$start_line-$end_line\t$is_case_arm_right\n";
      }
    ' "$file"
  )
done < <(find "$DIR" -type f -name '*.silica' -print0)

echo
echo "Total do/done...end occurrences remaining: $total_count"
echo "Occurrences on right side of case arms inside case statements: $case_arm_right_count"
