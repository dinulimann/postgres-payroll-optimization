-- Checks that an optimised run produced exactly the same numbers as the
-- reference run. Usage: psql -v ref=v1 -v cand=v3 -f 07_verify.sql

SET search_path TO payroll;

SELECT :'cand' AS run,
       (SELECT count(*) FROM payroll_summary WHERE run_label = :'cand') AS employees,
       (SELECT count(*) FROM (
            SELECT period, employee_id, segment_no, days_paid, days_present, base_salary, fixed_allowance, incentive
            FROM payroll_detail WHERE run_label = :'ref'
            EXCEPT
            SELECT period, employee_id, segment_no, days_paid, days_present, base_salary, fixed_allowance, incentive
            FROM payroll_detail WHERE run_label = :'cand'
        ) a) +
       (SELECT count(*) FROM (
            SELECT period, employee_id, segment_no, days_paid, days_present, base_salary, fixed_allowance, incentive
            FROM payroll_detail WHERE run_label = :'cand'
            EXCEPT
            SELECT period, employee_id, segment_no, days_paid, days_present, base_salary, fixed_allowance, incentive
            FROM payroll_detail WHERE run_label = :'ref'
        ) b) AS detail_diff_rows,
       (SELECT count(*) FROM (
            SELECT period, employee_id, gross, bpjs_health, pension, coop_mandatory, coop_voluntary, loan, net
            FROM payroll_summary WHERE run_label = :'ref'
            EXCEPT
            SELECT period, employee_id, gross, bpjs_health, pension, coop_mandatory, coop_voluntary, loan, net
            FROM payroll_summary WHERE run_label = :'cand'
        ) c) +
       (SELECT count(*) FROM (
            SELECT period, employee_id, gross, bpjs_health, pension, coop_mandatory, coop_voluntary, loan, net
            FROM payroll_summary WHERE run_label = :'cand'
            EXCEPT
            SELECT period, employee_id, gross, bpjs_health, pension, coop_mandatory, coop_voluntary, loan, net
            FROM payroll_summary WHERE run_label = :'ref'
        ) d) AS summary_diff_rows,
       (SELECT sum(net) FROM payroll_summary WHERE run_label = :'cand') AS total_net;
