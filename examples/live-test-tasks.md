# Live Test Tasks

Tasks for the sacrificial test repo. Each task is simple enough for Haiku
to implement correctly in one pass.

## Previously Completed Tasks

<!-- Autopilot moves completed task summaries here automatically. -->

---

## Task 1: Add multiply function

Add a `multiply(a, b)` function to `src/mathlib.py` that returns the product of two numbers. Write tests in `tests/test_mathlib.py` covering positive numbers, negative numbers, zero, and floats.

## Task 2: Add divide function with validation

Add a `divide(a, b)` function to `src/mathlib.py` that returns `a / b`. It must raise `ValueError` when `b` is zero. Write tests covering normal division, float results, negative numbers, and the zero-divisor error case.

## Task 3: Add factorial function

Add a `factorial(n)` function to `src/mathlib.py` that returns the factorial of a non-negative integer. It must return 1 for `factorial(0)` and raise `ValueError` for negative input. Write tests covering `factorial(0)`, `factorial(1)`, `factorial(5)`, and the negative-input error case.

## Task 4: Add tests for subtract function

The `subtract(a, b)` function exists in `src/mathlib.py` but has no tests. Add comprehensive tests in `tests/test_mathlib.py` covering: positive numbers, negative numbers, subtracting zero, subtracting from zero, and float inputs.

## Task 5: Extract input validation helper

Refactor `divide` and `factorial` to use a shared `validate_number(value, name)` helper that raises `TypeError` if the input is not a number. Add the helper to `src/mathlib.py` and write tests for it directly. Existing tests must still pass.

## Task 6: Add power function

Add a `power(base, exp)` function to `src/mathlib.py` that returns `base ** exp`. It must support negative exponents (returning a float). Write tests covering positive exponents, zero exponent, negative exponents, base of zero, and base of one.
