/-- Right-pad / truncate `s` to exactly `n` characters. -/
def padRight (s : String) (n : Nat) : String :=
  let truncated := String.ofList (s.toList.take n)
  truncated ++ String.ofList (List.replicate (n - truncated.length) ' ')
