-- v2: same procedural shape as v1, with the repeated work taken out of the loop.
--
-- This is the low-risk rewrite you can ship when the business rules are
-- complicated and the team wants to keep the step-by-step structure:
--   * parameters are read once, not once per employee per deduction
--   * attendance is aggregated per segment in ONE query up front
--   * rate lookups come from a pre-joined temp table
--   * cooperative and loan deductions are pre-aggregated per employee

SET search_path TO payroll;

CREATE OR REPLACE PROCEDURE v2_process_payroll(p_period date, p_run_label text)
LANGUAGE plpgsql AS $$
DECLARE
    v_start date := date_trunc('month', p_period)::date;
    v_end   date := (date_trunc('month', p_period) + interval '1 month - 1 day')::date;
    v_dim   int  := extract(day FROM v_end)::int;
    -- parameters, loaded once
    c_bpjs_rate numeric; c_bpjs_cap numeric; c_pension_rate numeric; c_min_thp numeric;
    emp record;
    seg record;
    v_seg_no int;
    v_base numeric; v_fixed numeric; v_inc numeric;
    v_sum_base numeric; v_sum_fixed numeric; v_gross numeric;
    v_running numeric;
    v_bpjs numeric; v_pension numeric; v_coop_m numeric; v_coop_v numeric; v_loan numeric;
BEGIN
    SELECT max(value) FILTER (WHERE key = 'bpjs_health_rate'),
           max(value) FILTER (WHERE key = 'bpjs_health_cap'),
           max(value) FILTER (WHERE key = 'pension_rate'),
           max(value) FILTER (WHERE key = 'min_take_home')
    INTO c_bpjs_rate, c_bpjs_cap, c_pension_rate, c_min_thp
    FROM params;

    DELETE FROM payroll_detail  WHERE run_label = p_run_label AND period = v_start;
    DELETE FROM payroll_summary WHERE run_label = p_run_label AND period = v_start;

    -- All segments of the period with their day counts and rates, in one pass.
    DROP TABLE IF EXISTS tmp_seg;
    CREATE TEMP TABLE tmp_seg ON COMMIT DROP AS
    WITH seg AS (
        SELECT a.employee_id,
               GREATEST(a.start_date, v_start, e.hire_date) AS seg_start,
               LEAST(COALESCE(a.end_date, v_end), v_end, COALESCE(e.end_date, v_end)) AS seg_end,
               g.base_salary, jc.fixed_allowance, jc.incentive
        FROM assignments a
        JOIN employees e    ON e.id = a.employee_id
        JOIN grades g       ON g.id = a.grade_id
        JOIN positions p    ON p.id = a.position_id
        JOIN job_classes jc ON jc.job_class = p.job_class
        WHERE e.hire_date <= v_end AND (e.end_date IS NULL OR e.end_date >= v_start)
          AND a.start_date <= v_end AND (a.end_date IS NULL OR a.end_date >= v_start)
    )
    SELECT s.*,
           row_number() OVER (PARTITION BY s.employee_id ORDER BY s.seg_start) AS seg_no,
           count(*) FILTER (WHERE at.status IN ('P', 'L'))::int AS days_paid,
           count(*) FILTER (WHERE at.status = 'P')::int        AS days_present
    FROM seg s
    LEFT JOIN attendance at
           ON at.employee_id = s.employee_id
          AND at.work_date BETWEEN s.seg_start AND s.seg_end
    WHERE s.seg_start <= s.seg_end
    GROUP BY s.employee_id, s.seg_start, s.seg_end, s.base_salary, s.fixed_allowance, s.incentive;

    CREATE INDEX ON tmp_seg (employee_id, seg_no);
    ANALYZE tmp_seg;

    DROP TABLE IF EXISTS tmp_ded;
    CREATE TEMP TABLE tmp_ded ON COMMIT DROP AS
    SELECT e.id AS employee_id,
           COALESCE(c.mandatory, 0) AS coop_m,
           COALESCE(c.voluntary, 0) AS coop_v,
           COALESCE((SELECT sum(l.monthly_installment) FROM loans l
                     WHERE l.employee_id = e.id AND l.active), 0) AS loan
    FROM employees e
    LEFT JOIN coop_members c ON c.employee_id = e.id;

    CREATE UNIQUE INDEX ON tmp_ded (employee_id);
    ANALYZE tmp_ded;

    FOR emp IN SELECT DISTINCT employee_id AS id FROM tmp_seg ORDER BY 1 LOOP
        v_seg_no := 0;
        v_sum_base := 0; v_sum_fixed := 0; v_gross := 0;

        FOR seg IN SELECT * FROM tmp_seg WHERE employee_id = emp.id ORDER BY seg_no LOOP
            v_seg_no := v_seg_no + 1;
            v_base  := round(seg.base_salary     * seg.days_paid    / v_dim, 2);
            v_fixed := round(seg.fixed_allowance * seg.days_paid    / v_dim, 2);
            v_inc   := round(seg.incentive       * seg.days_present / v_dim, 2);

            INSERT INTO payroll_detail VALUES
                (p_run_label, v_start, emp.id, v_seg_no, seg.days_paid, seg.days_present, v_base, v_fixed, v_inc);

            v_sum_base  := v_sum_base + v_base;
            v_sum_fixed := v_sum_fixed + v_fixed;
            v_gross     := v_gross + v_base + v_fixed + v_inc;
        END LOOP;

        SELECT coop_m, coop_v, loan INTO v_coop_m, v_coop_v, v_loan
        FROM tmp_ded WHERE employee_id = emp.id;

        v_running := v_gross;

        v_bpjs := LEAST(round(LEAST(v_sum_base + v_sum_fixed, c_bpjs_cap) * c_bpjs_rate, 2),
                        GREATEST(v_running - c_min_thp, 0));
        v_running := v_running - v_bpjs;

        v_pension := LEAST(round(v_sum_base * c_pension_rate, 2), GREATEST(v_running - c_min_thp, 0));
        v_running := v_running - v_pension;

        v_coop_m := LEAST(v_coop_m, GREATEST(v_running - c_min_thp, 0));
        v_running := v_running - v_coop_m;

        v_coop_v := LEAST(v_coop_v, GREATEST(v_running - c_min_thp, 0));
        v_running := v_running - v_coop_v;

        v_loan := LEAST(v_loan, GREATEST(v_running - c_min_thp, 0));
        v_running := v_running - v_loan;

        INSERT INTO payroll_summary VALUES
            (p_run_label, v_start, emp.id, v_gross, v_bpjs, v_pension, v_coop_m, v_coop_v, v_loan, v_running);
    END LOOP;
END $$;
