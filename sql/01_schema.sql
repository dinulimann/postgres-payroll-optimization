-- Payroll schema (simplified, anonymised).
-- Primary keys only: secondary indexes are added later in 04_indexes.sql so
-- the benchmark can show their effect separately.

DROP SCHEMA IF EXISTS payroll CASCADE;
CREATE SCHEMA payroll;
SET search_path TO payroll;

CREATE TABLE params (
    key   text PRIMARY KEY,
    value numeric NOT NULL
);

CREATE TABLE grades (
    id          int PRIMARY KEY,
    code        text NOT NULL,
    base_salary numeric(14,2) NOT NULL
);

CREATE TABLE job_classes (
    job_class        int PRIMARY KEY,
    fixed_allowance  numeric(14,2) NOT NULL,
    incentive        numeric(14,2) NOT NULL
);

CREATE TABLE positions (
    id        int PRIMARY KEY,
    code      text NOT NULL,
    job_class int NOT NULL REFERENCES job_classes
);

CREATE TABLE employees (
    id            int PRIMARY KEY,
    emp_no        text NOT NULL,
    full_name     text NOT NULL,
    location_type text NOT NULL CHECK (location_type IN ('HQ', 'BRANCH')),
    hire_date     date NOT NULL,
    end_date      date
);

-- One row per assignment. An employee who changes grade or position in the
-- middle of a month has two segments in that month.
CREATE TABLE assignments (
    id          int PRIMARY KEY,
    employee_id int  NOT NULL REFERENCES employees,
    start_date  date NOT NULL,
    end_date    date,
    grade_id    int  NOT NULL REFERENCES grades,
    position_id int  NOT NULL REFERENCES positions
);

-- One row per employee per calendar day.
-- P = present, L = paid leave, A = unpaid absence.
CREATE TABLE attendance (
    employee_id int  NOT NULL,
    work_date   date NOT NULL,
    status      char(1) NOT NULL CHECK (status IN ('P', 'L', 'A')),
    PRIMARY KEY (work_date, employee_id)   -- deliberately not led by employee_id
);

CREATE TABLE coop_members (
    employee_id int PRIMARY KEY,
    mandatory   numeric(14,2) NOT NULL,
    voluntary   numeric(14,2) NOT NULL
);

CREATE TABLE loans (
    id                  int PRIMARY KEY,
    employee_id         int NOT NULL,
    monthly_installment numeric(14,2) NOT NULL,
    active              boolean NOT NULL
);

-- Output tables
CREATE TABLE payroll_detail (
    run_label       text NOT NULL,
    period          date NOT NULL,
    employee_id     int  NOT NULL,
    segment_no      int  NOT NULL,
    days_paid       int  NOT NULL,
    days_present    int  NOT NULL,
    base_salary     numeric(14,2) NOT NULL,
    fixed_allowance numeric(14,2) NOT NULL,
    incentive       numeric(14,2) NOT NULL,
    PRIMARY KEY (run_label, period, employee_id, segment_no)
);

CREATE TABLE payroll_summary (
    run_label     text NOT NULL,
    period        date NOT NULL,
    employee_id   int  NOT NULL,
    gross         numeric(14,2) NOT NULL,
    bpjs_health   numeric(14,2) NOT NULL,
    pension       numeric(14,2) NOT NULL,
    coop_mandatory numeric(14,2) NOT NULL,
    coop_voluntary numeric(14,2) NOT NULL,
    loan          numeric(14,2) NOT NULL,
    net           numeric(14,2) NOT NULL,
    PRIMARY KEY (run_label, period, employee_id)
);
