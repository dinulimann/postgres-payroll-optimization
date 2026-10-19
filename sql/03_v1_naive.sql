-- v1: the "before" version.
--
-- This is how many payroll procedures grow over time: one loop per employee,
-- one loop per assignment segment, and a small helper function per component.
-- Each helper runs its own queries, so the same parameter and the same rows
-- are read thousands of times.

SET search_path TO payroll;

CREATE OR REPLACE FUNCTION v1_param(p_key text) RETURNS numeric
LANGUAGE plpgsql STABLE AS $$
DECLARE v numeric;
BEGIN
    SELECT value INTO v FROM params WHERE key = p_key;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION v1_count_days(p_emp int, p_from date, p_to date, p_statuses char[])
RETURNS int LANGUAGE plpgsql STABLE AS $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n
    FROM attendance
    WHERE employee_id = p_emp
      AND work_date BETWEEN p_from AND p_to
      AND status = ANY (p_statuses);
    RETURN n;
END $$;

CREATE OR REPLACE FUNCTION v1_base_salary(p_grade int, p_days int, p_days_in_month int)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE v numeric;
BEGIN
    SELECT base_salary INTO v FROM grades WHERE id = p_grade;
    RETURN round(v * p_days / p_days_in_month, 2);
END $$;

CREATE OR REPLACE FUNCTION v1_fixed_allowance(p_position int, p_days int, p_days_in_month int)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE v numeric;
BEGIN
    SELECT jc.fixed_allowance INTO v
    FROM positions p JOIN job_classes jc ON jc.job_class = p.job_class
    WHERE p.id = p_position;
    RETURN round(v * p_days / p_days_in_month, 2);
END $$;

CREATE OR REPLACE FUNCTION v1_incentive(p_position int, p_days int, p_days_in_month int)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE v numeric;
BEGIN
    SELECT jc.incentive INTO v
    FROM positions p JOIN job_classes jc ON jc.job_class = p.job_class
    WHERE p.id = p_position;
    RETURN round(v * p_days / p_days_in_month, 2);
END $$;

-- Caps a deduction so take-home pay never drops below the minimum.
CREATE OR REPLACE FUNCTION v1_apply_guard(p_amount numeric, p_running numeric)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN LEAST(p_amount, GREATEST(p_running - v1_param('min_take_home'), 0));
END $$;

CREATE OR REPLACE PROCEDURE v1_process_payroll(p_period date, p_run_label text)
LANGUAGE plpgsql AS $$
DECLARE
    v_start date := date_trunc('month', p_period)::date;
    v_end   date := (date_trunc('month', p_period) + interval '1 month - 1 day')::date;
    v_dim   int  := extract(day FROM v_end)::int;
    emp record;
    seg record;
    v_seg_no int;
    v_seg_start date;
    v_seg_end date;
    v_days_paid int;
    v_days_present int;
    v_base numeric; v_fixed numeric; v_inc numeric;
    v_sum_base numeric; v_sum_fixed numeric; v_gross numeric;
    v_running numeric;
    v_bpjs numeric; v_pension numeric; v_coop_m numeric; v_coop_v numeric; v_loan numeric;
    ln record;
BEGIN
    DELETE FROM payroll_detail  WHERE run_label = p_run_label AND period = v_start;
    DELETE FROM payroll_summary WHERE run_label = p_run_label AND period = v_start;

    FOR emp IN
        SELECT * FROM employees
        WHERE hire_date <= v_end AND (end_date IS NULL OR end_date >= v_start)
        ORDER BY id
    LOOP
        v_seg_no := 0;
        v_sum_base := 0; v_sum_fixed := 0; v_gross := 0;

        FOR seg IN
            SELECT * FROM assignments
            WHERE employee_id = emp.id
              AND start_date <= v_end
              AND (end_date IS NULL OR end_date >= v_start)
            ORDER BY start_date
        LOOP
            v_seg_start := GREATEST(seg.start_date, v_start, emp.hire_date);
            v_seg_end   := LEAST(COALESCE(seg.end_date, v_end), v_end, COALESCE(emp.end_date, v_end));
            CONTINUE WHEN v_seg_start > v_seg_end;
            v_seg_no := v_seg_no + 1;

            v_days_paid    := v1_count_days(emp.id, v_seg_start, v_seg_end, ARRAY['P','L']::char[]);
            v_days_present := v1_count_days(emp.id, v_seg_start, v_seg_end, ARRAY['P']::char[]);

            v_base  := v1_base_salary(seg.grade_id, v_days_paid, v_dim);
            v_fixed := v1_fixed_allowance(seg.position_id, v_days_paid, v_dim);
            v_inc   := v1_incentive(seg.position_id, v_days_present, v_dim);

            INSERT INTO payroll_detail VALUES
                (p_run_label, v_start, emp.id, v_seg_no, v_days_paid, v_days_present, v_base, v_fixed, v_inc);

            v_sum_base  := v_sum_base + v_base;
            v_sum_fixed := v_sum_fixed + v_fixed;
            v_gross     := v_gross + v_base + v_fixed + v_inc;
        END LOOP;

        CONTINUE WHEN v_seg_no = 0;

        v_running := v_gross;

        v_bpjs := round(LEAST(v_sum_base + v_sum_fixed, v1_param('bpjs_health_cap'))
                        * v1_param('bpjs_health_rate'), 2);
        v_bpjs := v1_apply_guard(v_bpjs, v_running);
        v_running := v_running - v_bpjs;

        v_pension := round(v_sum_base * v1_param('pension_rate'), 2);
        v_pension := v1_apply_guard(v_pension, v_running);
        v_running := v_running - v_pension;

        v_coop_m := COALESCE((SELECT mandatory FROM coop_members WHERE employee_id = emp.id), 0);
        v_coop_m := v1_apply_guard(v_coop_m, v_running);
        v_running := v_running - v_coop_m;

        v_coop_v := COALESCE((SELECT voluntary FROM coop_members WHERE employee_id = emp.id), 0);
        v_coop_v := v1_apply_guard(v_coop_v, v_running);
        v_running := v_running - v_coop_v;

        v_loan := 0;
        FOR ln IN SELECT * FROM loans WHERE employee_id = emp.id AND active LOOP
            v_loan := v_loan + ln.monthly_installment;
        END LOOP;
        v_loan := v1_apply_guard(v_loan, v_running);
        v_running := v_running - v_loan;

        INSERT INTO payroll_summary VALUES
            (p_run_label, v_start, emp.id, v_gross, v_bpjs, v_pension, v_coop_m, v_coop_v, v_loan, v_running);
    END LOOP;
END $$;
