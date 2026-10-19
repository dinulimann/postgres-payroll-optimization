-- v3: fully set-based. No loops: two INSERT ... SELECT statements.
--
-- The deduction "guard" (take-home pay may not drop below a minimum) looks
-- sequential, but each step only depends on the previous running balance, so
-- it can be written as a chain of LATERAL subqueries.

SET search_path TO payroll;

CREATE OR REPLACE PROCEDURE v3_process_payroll(p_period date, p_run_label text)
LANGUAGE plpgsql AS $$
DECLARE
    v_start date := date_trunc('month', p_period)::date;
    v_end   date := (date_trunc('month', p_period) + interval '1 month - 1 day')::date;
    v_dim   int  := extract(day FROM v_end)::int;
BEGIN
    DELETE FROM payroll_detail  WHERE run_label = p_run_label AND period = v_start;
    DELETE FROM payroll_summary WHERE run_label = p_run_label AND period = v_start;

    INSERT INTO payroll_detail
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
    ), counted AS (
        SELECT s.employee_id, s.seg_start, s.base_salary, s.fixed_allowance, s.incentive,
               count(*) FILTER (WHERE at.status IN ('P', 'L'))::int AS days_paid,
               count(*) FILTER (WHERE at.status = 'P')::int        AS days_present
        FROM seg s
        LEFT JOIN attendance at
               ON at.employee_id = s.employee_id
              AND at.work_date BETWEEN s.seg_start AND s.seg_end
        WHERE s.seg_start <= s.seg_end
        GROUP BY s.employee_id, s.seg_start, s.seg_end, s.base_salary, s.fixed_allowance, s.incentive
    )
    SELECT p_run_label, v_start, employee_id,
           row_number() OVER (PARTITION BY employee_id ORDER BY seg_start)::int,
           days_paid, days_present,
           round(base_salary     * days_paid    / v_dim, 2),
           round(fixed_allowance * days_paid    / v_dim, 2),
           round(incentive       * days_present / v_dim, 2)
    FROM counted;

    INSERT INTO payroll_summary
    WITH prm AS (
        SELECT max(value) FILTER (WHERE key = 'bpjs_health_rate') AS bpjs_rate,
               max(value) FILTER (WHERE key = 'bpjs_health_cap')  AS bpjs_cap,
               max(value) FILTER (WHERE key = 'pension_rate')     AS pension_rate,
               max(value) FILTER (WHERE key = 'min_take_home')    AS min_thp
        FROM params
    ), tot AS (
        SELECT employee_id,
               sum(base_salary) AS sum_base,
               sum(fixed_allowance) AS sum_fixed,
               sum(base_salary + fixed_allowance + incentive) AS gross
        FROM payroll_detail
        WHERE run_label = p_run_label AND period = v_start
        GROUP BY employee_id
    ), loan AS (
        SELECT employee_id, sum(monthly_installment) AS loan
        FROM loans WHERE active
        GROUP BY employee_id
    )
    SELECT p_run_label, v_start, t.employee_id, t.gross,
           d1.bpjs, d2.pension, d3.coop_m, d4.coop_v, d5.loan, d5.running
    FROM tot t
    CROSS JOIN prm
    LEFT JOIN coop_members c ON c.employee_id = t.employee_id
    LEFT JOIN loan l         ON l.employee_id = t.employee_id
    CROSS JOIN LATERAL (
        SELECT x AS bpjs, t.gross - x AS running
        FROM (SELECT LEAST(round(LEAST(t.sum_base + t.sum_fixed, prm.bpjs_cap) * prm.bpjs_rate, 2),
                           GREATEST(t.gross - prm.min_thp, 0)) AS x) q
    ) d1
    CROSS JOIN LATERAL (
        SELECT x AS pension, d1.running - x AS running
        FROM (SELECT LEAST(round(t.sum_base * prm.pension_rate, 2),
                           GREATEST(d1.running - prm.min_thp, 0)) AS x) q
    ) d2
    CROSS JOIN LATERAL (
        SELECT x AS coop_m, d2.running - x AS running
        FROM (SELECT LEAST(COALESCE(c.mandatory, 0), GREATEST(d2.running - prm.min_thp, 0)) AS x) q
    ) d3
    CROSS JOIN LATERAL (
        SELECT x AS coop_v, d3.running - x AS running
        FROM (SELECT LEAST(COALESCE(c.voluntary, 0), GREATEST(d3.running - prm.min_thp, 0)) AS x) q
    ) d4
    CROSS JOIN LATERAL (
        SELECT x AS loan, d4.running - x AS running
        FROM (SELECT LEAST(COALESCE(l.loan, 0), GREATEST(d4.running - prm.min_thp, 0)) AS x) q
    ) d5;
END $$;
