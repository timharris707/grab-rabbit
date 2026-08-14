# Lane brief template

The tracker item is the specification. A lane brief adds standing constraints and
mechanics; it never paraphrases the requirements into a second source of truth.

## Before generating the brief

1. Pick the item from the binding document's frontier.
2. Claim it with the read-before-write claim recipe. A live `Lane-start` refuses a
   second claim.
3. Create an item-named branch and linked worktree from the default branch.
4. Select and name the required verification from the binding document before work
   begins.

## Brief

```markdown
# Lane brief — item #<N>: <title>

## Spec
The spec is item #<N>; paste its body verbatim. Record deviations in the final
summary, and return deviations from a decided requirement to the decider.

## Required reading
- docs/agents/team-workflow.md
- The domain/context documents named by that binding

## Standing constraints
- Run the verification named for this item and check every command's own exit code.
- Commit checkpoints on the lane branch with short imperative subjects.
- The reviewer/integrator—not the lane—owns merge.
- Follow the binding document's precedence and exemption rules.

## Output contract
Post a tracker summary containing:
1. What landed, by file.
2. Verification commands and results.
3. Deviations and open questions.
```
