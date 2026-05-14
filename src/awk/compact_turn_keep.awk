# Calculate how many lines to keep from the tail of a conversation file,
# based on the ratio of user turns to preserve.
# Usage: awk -v ratio=0.12 -f compact_turn_keep.awk conv.jsonl
# Output: single integer (number of lines to keep from end)
BEGIN { target_turns = 0 }
{
    role[NR] = ($0 ~ /"role":"user"/ && $0 !~ /"content":\[/) ? "user" : "other"
}
END {
    if (NR == 0) { print 0; exit }
    for (i = 1; i <= NR; i++)
        if (role[i] == "user") total_turns++
    target = int(total_turns * ratio + 0.5)
    if (target < 1) target = 1
    if (target > total_turns) target = total_turns
    keep = 0; found = 0
    for (i = NR; i >= 1 && found < target; i--) {
        keep++
        if (role[i] == "user") found++
    }
    print (keep > 0 ? keep : 0)
}
