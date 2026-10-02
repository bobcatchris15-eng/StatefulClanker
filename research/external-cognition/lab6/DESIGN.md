# Lab 6: 16-Variable Ring Finite CSP Decomposition

## Aim

Test cooperative external cognition on a finite constraint satisfaction problem where the global state space is computationally intractable for monolithic forward-pass reasoning ($4^{16} \approx 4.3 \times 10^9$ states), while local component state spaces remain compact ($4^4 = 256$ states). The experiment tests whether multi-agent component decomposition with a shared claim/review protocol enables solving global constraint networks where raw monolithic inference fails.

## Problem Topology: 4-Component Ring

Each instance features 16 variables `a` through `p`, each with domain $\{0, 1, 2, 3\}$:
- **Component 1 ($C_1$)**: variables `(a, b, c, d)`
- **Component 2 ($C_2$)**: variables `(e, f, g, h)`
- **Component 3 ($C_3$)**: variables `(i, j, k, l)`
- **Component 4 ($C_4$)**: variables `(m, n, o, p)`

### Constraints (20 total binary constraints):
1. **Internal cycle constraints (16)**:
   - $C_1$: `(a,b), (b,c), (c,d), (d,a)`
   - $C_2$: `(e,f), (f,g), (g,h), (h,e)`
   - $C_3$: `(i,j), (j,k), (k,l), (l,i)`
   - $C_4$: `(m,n), (n,o), (o,p), (p,m)`
2. **Bridge constraints (4, forming a closed ring)**:
   - $B_{12}$: `(b, e)` connecting $C_1$ and $C_2$
   - $B_{23}$: `(f, i)` connecting $C_2$ and $C_3$
   - $B_{34}$: `(j, m)` connecting $C_3$ and $C_4$
   - $B_{41}$: `(n, a)` connecting $C_4$ and $C_1$

### Complexity Asymmetry:
- **Raw Monolithic Search Space**: $4^{16} = 4,294,967,296$ combinations.
- **Local Component Search Space**: $4^4 = 256$ combinations per component.
- **Decomposed Assembly Space**: With $K_i \in [3, 8]$ valid local tuples per component, the shared integrator searches at most $8 \times 8 \times 8 \times 8 = 4,096$ candidate combinations across the 4 bridge constraints.

## Frozen Seeds

Instances are generated with a planted 16-variable assignment, 5 distractors per internal edge (6 allowed pairs out of 16), and 1 distractor per bridge edge (2 allowed pairs out of 16). The 6 frozen seeds scanning from 6100 are:
`6112, 6135, 6412, 6432, 6459, 6582`
Each seed has exactly 1 global solution and each component has between 3 and 8 local solutions.

## Protocol Roles & Execution Phases

Each instance uses 10 stateless call slots:
1. **Phase 1: Proposers (4 concurrent calls)**
   - `c1-proposer`, `c2-proposer`, `c3-proposer`, `c4-proposer`
   - Each outputs an envelope with `intent: PROPOSE` containing the complete list of valid 4-tuples for its component.
2. **Phase 2: Reviewers (4 concurrent calls)**
   - `c1-reviewer`: reviews $C_2$ proposal across bridge `(b, e)`
   - `c2-reviewer`: reviews $C_3$ proposal across bridge `(f, i)`
   - `c3-reviewer`: reviews $C_4$ proposal across bridge `(j, m)`
   - `c4-reviewer`: reviews $C_1$ proposal across bridge `(n, a)`
3. **Phase 3: Integrators (2 parallel calls)**
   - `shared-integrator`: receives the public packet + the shared projection containing all 4 component claims and review reports.
   - `raw-integrator`: receives the exact same public packet without decomposed claims or review messages.
