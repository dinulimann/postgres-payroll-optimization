-- Step 1 of the optimisation: indexes that match how the payroll reads data.
-- Every per-employee lookup in v1 filters on employee_id, but none of these
-- tables had an index that starts with it.

SET search_path TO payroll;

CREATE INDEX IF NOT EXISTS ix_attendance_emp_date ON attendance (employee_id, work_date) INCLUDE (status);
CREATE INDEX IF NOT EXISTS ix_assignments_emp     ON assignments (employee_id, start_date);
CREATE INDEX IF NOT EXISTS ix_loans_emp_active    ON loans (employee_id) WHERE active;

ANALYZE attendance;
ANALYZE assignments;
ANALYZE loans;
