# /parallel - Parallel Agent Execution via Git Worktree

Set up parallel agent execution using Git worktrees for multi-agent workflows.

## Instructions

Help the user set up and manage parallel Claude Code sessions using Git worktrees.

### Available Strategies

**Strategy 1: Multi-Agent Division**
Different agents work on different tasks simultaneously.

1. Ask the user to list the independent tasks to parallelize.
2. For each task, create a worktree and branch:
   ```bash
   claude --worktree task-name-1 --tmux
   claude --worktree task-name-2 --tmux
   ```
3. Ensure tasks have clear API boundaries - shared interfaces must be agreed upon BEFORE parallel execution.
4. After all tasks complete, merge branches sequentially, resolving conflicts.

**Strategy 2: Best-of-N**
Multiple agents attempt the same task; pick the best result.

1. Create N worktrees for the same task:
   ```bash
   for i in $(seq 1 $N); do
     claude --worktree attempt-$i --tmux
   done
   ```
2. Each agent works independently on the same spec.
3. Compare results using tests, code quality metrics, or manual review.
4. Keep the best implementation, discard others.

### Prerequisites

- Git repository initialized
- Sufficient disk space for worktree copies
- tmux installed (for background execution)

### Warnings

- Do NOT parallelize tasks that modify the same files
- Shared databases/Docker daemons may cause race conditions across worktrees
- Define shared interfaces BEFORE starting parallel work

### After Parallel Work

1. List all worktrees: `git worktree list`
2. Review each branch's changes
3. Merge the chosen branch(es)
4. Clean up: `git worktree remove <path>`
