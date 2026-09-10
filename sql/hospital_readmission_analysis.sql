-- ============================================================
-- HOSPITAL PATIENT READMISSION ANALYSIS
-- Dataset : UCI Diabetes 130-US Hospitals (1999-2008)
-- MySQL   : 8.0+
-- Sections: 01 Setup · 02 Inspect · 03 QC · 04 Clean
--           05 Dedup · 06 Filter · 07 Features · 08 Maps
--           09 EDA · 10 Advanced · 11 Business · 12 View · 13 Validate
-- ============================================================

-- ── 01. DATABASE SETUP ──────────────────────────────────────
CREATE DATABASE IF NOT EXISTS hospital_readmissions
    CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE hospital_readmissions;


-- ── 02. RAW DATA INSPECTION ─────────────────────────────────
SELECT * FROM diabetic_data_raw LIMIT 10;
DESCRIBE diabetic_data_raw;
SELECT COUNT(*) AS total_rows FROM diabetic_data_raw;   -- expect ~101,766


-- ── 03. DATA QUALITY CHECKS ─────────────────────────────────

-- Unique encounters vs patients (encounter_id should equal total_rows)
SELECT
    COUNT(*)                     AS total_rows,
    COUNT(DISTINCT encounter_id) AS unique_encounters,
    COUNT(DISTINCT patient_nbr)  AS unique_patients
FROM diabetic_data_raw;

-- Duplicate encounter_ids (expect 0 rows)
SELECT encounter_id, COUNT(*) AS cnt
FROM diabetic_data_raw
GROUP BY encounter_id HAVING COUNT(*) > 1
ORDER BY cnt DESC LIMIT 10;

-- Patients with multiple encounters (legitimate, NOT duplicates)
SELECT COUNT(*) AS patients_with_multiple_encounters
FROM (
    SELECT patient_nbr FROM diabetic_data_raw
    GROUP BY patient_nbr HAVING COUNT(*) > 1
) t;

-- Readmission category distribution
SELECT readmitted, COUNT(*) AS cnt,
    ROUND(COUNT(*) / (SELECT COUNT(*) FROM diabetic_data_raw) * 100, 1) AS pct
FROM diabetic_data_raw
GROUP BY readmitted ORDER BY cnt DESC;

-- '?' missing value rates per column
SELECT
    ROUND(SUM(race              = '?') / COUNT(*) * 100, 1) AS pct_race,
    ROUND(SUM(weight            = '?') / COUNT(*) * 100, 1) AS pct_weight,
    ROUND(SUM(payer_code        = '?') / COUNT(*) * 100, 1) AS pct_payer,
    ROUND(SUM(medical_specialty = '?') / COUNT(*) * 100, 1) AS pct_specialty,
    ROUND(SUM(diag_1            = '?') / COUNT(*) * 100, 1) AS pct_diag1,
    ROUND(SUM(diag_2            = '?') / COUNT(*) * 100, 1) AS pct_diag2,
    ROUND(SUM(diag_3            = '?') / COUNT(*) * 100, 1) AS pct_diag3
FROM diabetic_data_raw;

-- Age, gender, discharge distribution
SELECT age,    COUNT(*) AS cnt FROM diabetic_data_raw GROUP BY age    ORDER BY age;
SELECT gender, COUNT(*) AS cnt FROM diabetic_data_raw GROUP BY gender;
SELECT discharge_disposition_id, COUNT(*) AS cnt
FROM diabetic_data_raw GROUP BY discharge_disposition_id ORDER BY cnt DESC;

-- Non-numeric ICD-9 codes in diag_1 (E-codes, V-codes)
SELECT diag_1, COUNT(*) AS cnt
FROM diabetic_data_raw
WHERE diag_1 NOT REGEXP '^[0-9]' AND diag_1 IS NOT NULL AND diag_1 != '?'
GROUP BY diag_1 ORDER BY cnt DESC LIMIT 20;

-- A1C and medication change categories
SELECT A1Cresult,         COUNT(*) AS cnt FROM diabetic_data_raw GROUP BY A1Cresult;
SELECT change_medication, COUNT(*) AS cnt FROM diabetic_data_raw GROUP BY change_medication;


-- ── 04. DATA CLEANING ───────────────────────────────────────
-- '?' → NULL (SQL standard for unknown; keeps aggregations unbiased)

SET SQL_SAFE_UPDATES = 0;

ALTER TABLE diabetic_data_raw
    MODIFY COLUMN diag_1 VARCHAR(10),
    MODIFY COLUMN diag_2 VARCHAR(10),
    MODIFY COLUMN diag_3 VARCHAR(10);

UPDATE diabetic_data_raw
SET
    race              = NULLIF(race,              '?'),
    weight            = NULLIF(weight,            '?'),
    payer_code        = NULLIF(payer_code,        '?'),
    medical_specialty = NULLIF(medical_specialty, '?'),
    diag_1            = NULLIF(diag_1,            '?'),
    diag_2            = NULLIF(diag_2,            '?'),
    diag_3            = NULLIF(diag_3,            '?');

SET SQL_SAFE_UPDATES = 1;

-- Verify null rates match the '?' rates from Section 03
SELECT
    ROUND(SUM(race IS NULL) / COUNT(*) * 100, 1)              AS pct_race_null,
    ROUND(SUM(weight IS NULL) / COUNT(*) * 100, 1)            AS pct_weight_null,
    ROUND(SUM(payer_code IS NULL) / COUNT(*) * 100, 1)        AS pct_payer_null,
    ROUND(SUM(medical_specialty IS NULL) / COUNT(*) * 100, 1) AS pct_specialty_null
FROM diabetic_data_raw;


-- ── 05. ENCOUNTER VALIDATION & DEDUPLICATION ────────────────
-- Keep ALL encounters. Use SELECT DISTINCT to remove only exact duplicate rows.
-- DO NOT use MIN(encounter_id) GROUP BY patient — that deletes legitimate
-- repeat visits needed for readmission analysis.

DROP TABLE IF EXISTS diabetic_data_clean;
CREATE TABLE diabetic_data_clean AS SELECT DISTINCT * FROM diabetic_data_raw;

SELECT COUNT(*) AS rows_after_dedup,
       COUNT(DISTINCT encounter_id) AS unique_encounters,
       COUNT(DISTINCT patient_nbr)  AS unique_patients
FROM diabetic_data_clean;   -- expect same count as raw


-- ── 06. DISCHARGE FILTERING ─────────────────────────────────
-- Exclude encounters where patient died or entered hospice
-- (they cannot be readmitted, so they bias the denominator).
-- IDs: 11=Expired 13=Hospice-Home 14=Hospice-Facility
--      19/20/21=Expired (Medicaid hospice variants)
-- IDs 25/26 (Not Mapped / Unknown) are KEPT — not indicative of death.

-- Preview before deleting
SELECT discharge_disposition_id, COUNT(*) AS cnt
FROM diabetic_data_clean
WHERE discharge_disposition_id IN (11, 13, 14, 19, 20, 21)
GROUP BY discharge_disposition_id ORDER BY discharge_disposition_id;

SET SQL_SAFE_UPDATES = 0;
DELETE FROM diabetic_data_clean WHERE discharge_disposition_id IN (11, 13, 14, 19, 20, 21);
SET SQL_SAFE_UPDATES = 1;

SELECT COUNT(*) AS rows_after_filter FROM diabetic_data_clean;   -- expect ~98,052


-- ── 07. FEATURE ENGINEERING ─────────────────────────────────

SET SQL_SAFE_UPDATES = 0;

-- 07-A  age_midpoint: numeric midpoint of age bracket for quantitative analysis
ALTER TABLE diabetic_data_clean ADD COLUMN age_midpoint TINYINT UNSIGNED AFTER age;
UPDATE diabetic_data_clean SET age_midpoint = CASE
    WHEN age = '[0-10)'   THEN 5   WHEN age = '[10-20)'  THEN 15
    WHEN age = '[20-30)'  THEN 25  WHEN age = '[30-40)'  THEN 35
    WHEN age = '[40-50)'  THEN 45  WHEN age = '[50-60)'  THEN 55
    WHEN age = '[60-70)'  THEN 65  WHEN age = '[70-80)'  THEN 75
    WHEN age = '[80-90)'  THEN 85  WHEN age = '[90-100)' THEN 95
    ELSE NULL
END;

-- 07-B  is_readmitted_30: binary flag (1 = readmitted <30 days, 0 = otherwise)
--       Enables AVG() as a rate, SUM() as a count, and ML label.
--       Original 'readmitted' column is kept for '>30' vs 'NO' analysis.
ALTER TABLE diabetic_data_clean
    ADD COLUMN is_readmitted_30 TINYINT(1) NOT NULL DEFAULT 0 AFTER readmitted;
UPDATE diabetic_data_clean
    SET is_readmitted_30 = CASE WHEN readmitted = '<30' THEN 1 ELSE 0 END;

-- 07-C  medication_burden_tier (analytical segment, not clinical)
ALTER TABLE diabetic_data_clean ADD COLUMN medication_burden_tier VARCHAR(10) AFTER num_medications;
UPDATE diabetic_data_clean SET medication_burden_tier = CASE
    WHEN num_medications <= 10             THEN 'Low'
    WHEN num_medications BETWEEN 11 AND 20 THEN 'Medium'
    ELSE 'High'
END;

-- 07-D  diagnosis_complexity_tier (analytical segment, not clinical)
ALTER TABLE diabetic_data_clean ADD COLUMN diagnosis_complexity_tier VARCHAR(20) AFTER number_diagnoses;
UPDATE diabetic_data_clean SET diagnosis_complexity_tier = CASE
    WHEN number_diagnoses <= 5            THEN 'Low Complexity'
    WHEN number_diagnoses BETWEEN 6 AND 9 THEN 'Moderate Complexity'
    ELSE 'High Complexity'
END;

-- 07-E  diagnosis_category from diag_1 (ICD-9)
--       E% / V% guards run BEFORE the CAST so non-numeric codes never reach it.
ALTER TABLE diabetic_data_clean ADD COLUMN diagnosis_category VARCHAR(20) AFTER diag_1;
UPDATE diabetic_data_clean SET diagnosis_category = CASE
    WHEN diag_1 LIKE '250%'                                                          THEN 'Diabetes'
    WHEN diag_1 LIKE 'E%'                                                            THEN 'Injury'
    WHEN diag_1 LIKE 'V%'                                                            THEN 'Other'
    WHEN diag_1 REGEXP '^[0-9]' AND CAST(LEFT(diag_1,3) AS UNSIGNED) BETWEEN 390 AND 459 THEN 'Circulatory'
    WHEN diag_1 REGEXP '^[0-9]' AND CAST(LEFT(diag_1,3) AS UNSIGNED) BETWEEN 460 AND 519 THEN 'Respiratory'
    WHEN diag_1 REGEXP '^[0-9]' AND CAST(LEFT(diag_1,3) AS UNSIGNED) BETWEEN 520 AND 579 THEN 'Digestive'
    WHEN diag_1 REGEXP '^[0-9]' AND CAST(LEFT(diag_1,3) AS UNSIGNED) BETWEEN 580 AND 629 THEN 'Genitourinary'
    WHEN diag_1 REGEXP '^[0-9]' AND CAST(LEFT(diag_1,3) AS UNSIGNED) BETWEEN 800 AND 999 THEN 'Injury'
    WHEN diag_1 IS NULL THEN NULL
    ELSE 'Other'
END;

SET SQL_SAFE_UPDATES = 1;


-- ── 08. MAPPING TABLES ──────────────────────────────────────

DROP TABLE IF EXISTS discharge_disposition_map;
CREATE TABLE discharge_disposition_map (discharge_disposition_id INT PRIMARY KEY, description VARCHAR(200) NOT NULL);
INSERT INTO discharge_disposition_map VALUES
(1,'Discharged to Home'),(2,'Transferred to Short-Term Hospital'),
(3,'Transferred to Skilled Nursing Facility'),(4,'Transferred to Intermediate Care Facility'),
(5,'Transferred to Another Inpatient Care Institution'),(6,'Discharged to Home with Home Health Service'),
(7,'Left Against Medical Advice (AMA)'),(8,'Discharged to Home Under IV Provider Care'),
(9,'Admitted as Inpatient to This Hospital'),(10,'Neonate Transferred to Another Hospital'),
(11,'Expired'),(12,'Still Patient / Expected Outpatient Return'),
(13,'Hospice - Home'),(14,'Hospice - Medical Facility'),
(15,'Transferred - Medicare Swing Bed'),(16,'Transferred/Referred - Outpatient Services Elsewhere'),
(17,'Transferred/Referred - Outpatient Services Here'),(18,'Not Available'),
(19,'Expired at Home (Medicaid Hospice)'),(20,'Expired in Medical Facility (Medicaid Hospice)'),
(21,'Expired - Place Unknown (Medicaid Hospice)'),(22,'Transferred to Rehabilitation Facility'),
(23,'Transferred to Long-Term Care Hospital'),(24,'Transferred to Medicaid-Only Nursing Facility'),
(25,'Not Mapped'),(26,'Unknown/Invalid'),(27,'Transferred to Federal Healthcare Facility'),
(28,'Transferred to Psychiatric Hospital'),(29,'Transferred to Critical Access Hospital'),
(30,'Transferred to Other Health Care Institution');

DROP TABLE IF EXISTS admission_source_map;
CREATE TABLE admission_source_map (admission_source_id INT PRIMARY KEY, description VARCHAR(200) NOT NULL);
INSERT INTO admission_source_map VALUES
(1,'Physician Referral'),(2,'Clinic Referral'),(3,'HMO Referral'),
(4,'Transfer from Hospital'),(5,'Transfer from Skilled Nursing Facility'),
(6,'Transfer from Another Health Care Facility'),(7,'Emergency Room'),
(8,'Court/Law Enforcement'),(9,'Not Available'),(10,'Transfer from Critical Access Hospital'),
(11,'Normal Delivery'),(12,'Premature Delivery'),(13,'Sick Baby'),(14,'Extramural Birth'),
(15,'Not Available'),(17,'Not Available'),(18,'Transfer from Another Home Health Agency'),
(19,'Readmission to Same Home Health Agency'),(20,'Not Mapped'),(21,'Unknown/Invalid'),
(22,'Transfer from Hospital (Separate Claim)'),(23,'Born Inside This Hospital'),
(24,'Born Outside This Hospital'),(25,'Transfer from Ambulatory Surgery Center'),
(26,'Transfer from Hospice');

DROP TABLE IF EXISTS admission_type_map;
CREATE TABLE admission_type_map (admission_type_id INT PRIMARY KEY, description VARCHAR(100) NOT NULL);
INSERT INTO admission_type_map VALUES
(1,'Emergency'),(2,'Urgent'),(3,'Elective'),(4,'Newborn'),
(5,'Not Available'),(6,'Not Available'),(7,'Trauma Center'),(8,'Not Mapped');


-- ── 09. EXPLORATORY ANALYSIS ────────────────────────────────

-- 09-01 Overall summary
SELECT
    COUNT(*)                                          AS total_encounters,
    COUNT(DISTINCT patient_nbr)                       AS unique_patients,
    SUM(is_readmitted_30)                             AS readmitted_30_day,
    ROUND(AVG(is_readmitted_30) * 100, 1)            AS readmission_rate_pct,
    ROUND(SUM(readmitted='>30') / COUNT(*)*100, 1)   AS pct_after_30,
    ROUND(SUM(readmitted='NO')  / COUNT(*)*100, 1)   AS pct_not_readmitted
FROM diabetic_data_clean;

-- 09-02 By age group
SELECT age, age_midpoint, COUNT(*) AS total,
    SUM(is_readmitted_30) AS readmitted_30,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean GROUP BY age, age_midpoint ORDER BY age_midpoint;

-- 09-03 By gender
SELECT gender, COUNT(*) AS total, SUM(is_readmitted_30) AS readmitted_30,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean WHERE gender != 'Unknown/Invalid'
GROUP BY gender ORDER BY rate_pct DESC;

-- 09-04 By race
SELECT COALESCE(race,'Unknown') AS race, COUNT(*) AS total,
    SUM(is_readmitted_30) AS readmitted_30,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean GROUP BY race ORDER BY total DESC;

-- 09-05 By admission type
SELECT m.description AS admission_type, COUNT(*) AS total,
    SUM(d.is_readmitted_30) AS readmitted_30,
    ROUND(AVG(d.is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean d JOIN admission_type_map m USING (admission_type_id)
GROUP BY m.description ORDER BY rate_pct DESC;

-- 09-06 By admission source
SELECT m.description AS admission_source, COUNT(*) AS total,
    SUM(d.is_readmitted_30) AS readmitted_30,
    ROUND(AVG(d.is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean d JOIN admission_source_map m USING (admission_source_id)
GROUP BY m.description HAVING COUNT(*) > 200 ORDER BY rate_pct DESC;

-- 09-07 By diagnosis category
SELECT COALESCE(diagnosis_category,'Unknown') AS diagnosis_category,
    COUNT(*) AS total, SUM(is_readmitted_30) AS readmitted_30,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean GROUP BY diagnosis_category ORDER BY rate_pct DESC;

-- 09-08 By number of diagnoses
SELECT number_diagnoses, COUNT(*) AS total, SUM(is_readmitted_30) AS readmitted_30,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean GROUP BY number_diagnoses ORDER BY number_diagnoses;

-- 09-09 By time in hospital (length of stay)
SELECT time_in_hospital AS days, COUNT(*) AS total, SUM(is_readmitted_30) AS readmitted_30,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean GROUP BY time_in_hospital ORDER BY time_in_hospital;

-- 09-10 By number of medications
SELECT num_medications, COUNT(*) AS total, SUM(is_readmitted_30) AS readmitted_30,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean GROUP BY num_medications ORDER BY num_medications;

-- 09-11 By A1C result
SELECT COALESCE(A1Cresult,'Not Tested') AS a1c_result, COUNT(*) AS total,
    SUM(is_readmitted_30) AS readmitted_30,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean GROUP BY A1Cresult ORDER BY rate_pct DESC;

-- 09-12 By medication change (association, NOT causation)
SELECT CASE change_medication WHEN 'Ch' THEN 'Changed' WHEN 'No' THEN 'Not Changed' ELSE change_medication END AS med_change,
    COUNT(*) AS total, SUM(is_readmitted_30) AS readmitted_30,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean GROUP BY change_medication ORDER BY rate_pct DESC;

-- 09-13 By prior inpatient visits
SELECT number_inpatient AS prior_inpatient, COUNT(*) AS total,
    SUM(is_readmitted_30) AS readmitted_30,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean GROUP BY number_inpatient ORDER BY number_inpatient;

-- 09-14 By prior emergency visits
SELECT number_emergency AS prior_emergency, COUNT(*) AS total,
    SUM(is_readmitted_30) AS readmitted_30,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean GROUP BY number_emergency ORDER BY number_emergency;

-- 09-15 By prior outpatient visits
SELECT number_outpatient AS prior_outpatient, COUNT(*) AS total,
    SUM(is_readmitted_30) AS readmitted_30,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean GROUP BY number_outpatient ORDER BY number_outpatient;

-- 09-16 By discharge disposition
SELECT m.description AS discharge_disposition, COUNT(*) AS total,
    SUM(d.is_readmitted_30) AS readmitted_30,
    ROUND(AVG(d.is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean d JOIN discharge_disposition_map m USING (discharge_disposition_id)
GROUP BY m.description HAVING COUNT(*) > 100 ORDER BY rate_pct DESC;


-- ── 10. ADVANCED SQL ANALYSIS ───────────────────────────────

-- 10-A  Prior inpatient utilization quartiles (NTILE)
WITH q AS (
    SELECT encounter_id, number_inpatient, is_readmitted_30,
        NTILE(4) OVER (ORDER BY number_inpatient) AS quartile
    FROM diabetic_data_clean
)
SELECT quartile,
    CASE quartile WHEN 1 THEN 'Q1 - Lowest' WHEN 4 THEN 'Q4 - Highest' ELSE CONCAT('Q',quartile) END AS label,
    COUNT(*) AS total, SUM(is_readmitted_30) AS readmitted_30,
    MIN(number_inpatient) AS min_inpatient, MAX(number_inpatient) AS max_inpatient,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM q GROUP BY quartile ORDER BY quartile;

-- 10-B  Medication rank within age group (RANK + PARTITION)
WITH ranked AS (
    SELECT encounter_id, age_midpoint, num_medications, is_readmitted_30,
        RANK() OVER (PARTITION BY age_midpoint ORDER BY num_medications DESC) AS med_rank
    FROM diabetic_data_clean
)
SELECT encounter_id, age_midpoint, num_medications, med_rank, is_readmitted_30
FROM ranked WHERE med_rank <= 10
ORDER BY age_midpoint, med_rank LIMIT 100;

-- 10-C  Readmission rate by medication tier x complexity tier (interaction)
SELECT medication_burden_tier, diagnosis_complexity_tier,
    COUNT(*) AS total, SUM(is_readmitted_30) AS readmitted_30,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean
GROUP BY medication_burden_tier, diagnosis_complexity_tier
ORDER BY rate_pct DESC;

-- 10-D  Diagnosis categories with above-average readmission rate
WITH cat AS (
    SELECT diagnosis_category, COUNT(*) AS total,
        ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
    FROM diabetic_data_clean WHERE diagnosis_category IS NOT NULL
    GROUP BY diagnosis_category
),
overall AS (SELECT ROUND(AVG(is_readmitted_30)*100,1) AS overall_pct FROM diabetic_data_clean)
SELECT c.diagnosis_category, c.total, c.rate_pct, o.overall_pct,
    ROUND(c.rate_pct - o.overall_pct, 1) AS pct_above_avg
FROM cat c CROSS JOIN overall o
WHERE c.rate_pct > o.overall_pct ORDER BY pct_above_avg DESC;


-- ── 11. BUSINESS QUESTIONS ──────────────────────────────────
-- All findings describe associations, NOT causation.

-- BQ-01  Overall 30-day readmission rate
SELECT COUNT(*) AS total, SUM(is_readmitted_30) AS readmitted_30,
    ROUND(AVG(is_readmitted_30)*100,2) AS rate_pct
FROM diabetic_data_clean;

-- BQ-02  Top 5 age groups by readmission rate
SELECT age, age_midpoint, COUNT(*) AS total,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean GROUP BY age, age_midpoint
ORDER BY rate_pct DESC LIMIT 5;

-- BQ-03  Diagnosis categories vs overall average
WITH ov AS (SELECT AVG(is_readmitted_30) AS avg_rate FROM diabetic_data_clean)
SELECT d.diagnosis_category, COUNT(*) AS total,
    ROUND(AVG(d.is_readmitted_30)*100,1) AS rate_pct,
    ROUND(o.avg_rate*100,1) AS overall_pct,
    CASE WHEN AVG(d.is_readmitted_30) > o.avg_rate THEN 'Above Avg' ELSE 'At/Below Avg' END AS vs_overall
FROM diabetic_data_clean d CROSS JOIN ov o
WHERE d.diagnosis_category IS NOT NULL
GROUP BY d.diagnosis_category, o.avg_rate ORDER BY rate_pct DESC;

-- BQ-04  Medication change association
SELECT CASE change_medication WHEN 'Ch' THEN 'Changed' WHEN 'No' THEN 'Not Changed' ELSE 'Other' END AS med_change,
    COUNT(*) AS total, SUM(is_readmitted_30) AS readmitted_30,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean GROUP BY change_medication;

-- BQ-05  A1C status association
SELECT COALESCE(A1Cresult,'Not Tested') AS a1c, COUNT(*) AS total,
    SUM(is_readmitted_30) AS readmitted_30, ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean GROUP BY A1Cresult ORDER BY rate_pct DESC;

-- BQ-06  Discharge disposition with highest readmission rates
SELECT m.description AS disposition, COUNT(*) AS total,
    SUM(d.is_readmitted_30) AS readmitted_30,
    ROUND(AVG(d.is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean d JOIN discharge_disposition_map m USING (discharge_disposition_id)
GROUP BY m.description HAVING COUNT(*) > 100 ORDER BY rate_pct DESC LIMIT 10;

-- BQ-07  Prior inpatient utilization bands
SELECT CASE
        WHEN number_inpatient = 0             THEN '0'
        WHEN number_inpatient BETWEEN 1 AND 2 THEN '1-2'
        WHEN number_inpatient BETWEEN 3 AND 5 THEN '3-5'
        ELSE '6+' END AS prior_inpatient,
    COUNT(*) AS total, SUM(is_readmitted_30) AS readmitted_30,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean GROUP BY prior_inpatient ORDER BY rate_pct DESC;

-- BQ-08  Prior emergency utilization bands
SELECT CASE
        WHEN number_emergency = 0             THEN '0'
        WHEN number_emergency BETWEEN 1 AND 2 THEN '1-2'
        WHEN number_emergency BETWEEN 3 AND 5 THEN '3-5'
        ELSE '6+' END AS prior_emergency,
    COUNT(*) AS total, SUM(is_readmitted_30) AS readmitted_30,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean GROUP BY prior_emergency ORDER BY rate_pct DESC;

-- BQ-09  Diagnosis complexity tiers
SELECT diagnosis_complexity_tier, COUNT(*) AS total,
    SUM(is_readmitted_30) AS readmitted_30,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean GROUP BY diagnosis_complexity_tier ORDER BY rate_pct DESC;

-- BQ-10  Medication burden tiers
SELECT medication_burden_tier, COUNT(*) AS total,
    SUM(is_readmitted_30) AS readmitted_30,
    ROUND(AVG(is_readmitted_30)*100,1) AS rate_pct
FROM diabetic_data_clean GROUP BY medication_burden_tier
ORDER BY FIELD(medication_burden_tier,'Low','Medium','High');


-- ── 12. FINAL ANALYTICAL VIEW ───────────────────────────────
-- Denormalized view for Python / Power BI. LEFT JOINs prevent row multiplication.

DROP VIEW IF EXISTS vw_readmission_analysis;
CREATE VIEW vw_readmission_analysis AS
SELECT
    d.encounter_id, d.patient_nbr,
    d.age, d.age_midpoint, d.gender, COALESCE(d.race,'Unknown') AS race,
    d.admission_type_id,    atm.description  AS admission_type,
    d.admission_source_id,  asm.description  AS admission_source,
    d.discharge_disposition_id, dd.description AS discharge_disposition,
    d.time_in_hospital, d.num_medications, d.num_lab_procedures, d.number_diagnoses,
    d.number_inpatient, d.number_emergency, d.number_outpatient,
    d.diag_1, d.diag_2, d.diag_3, d.diagnosis_category,
    d.A1Cresult, d.change_medication AS medication_change,
    d.medication_burden_tier, d.diagnosis_complexity_tier,
    d.readmitted, d.is_readmitted_30
FROM diabetic_data_clean d
LEFT JOIN admission_type_map        atm ON d.admission_type_id        = atm.admission_type_id
LEFT JOIN admission_source_map      asm ON d.admission_source_id      = asm.admission_source_id
LEFT JOIN discharge_disposition_map dd  ON d.discharge_disposition_id = dd.discharge_disposition_id;

SELECT COUNT(*) AS view_rows FROM vw_readmission_analysis;


-- ── 13. VALIDATION & INDEXES ────────────────────────────────

-- V-01  Row, encounter, patient counts
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT encounter_id) AS encounters,
    COUNT(DISTINCT patient_nbr) AS patients FROM diabetic_data_clean;

-- V-02  is_readmitted_30 must be only 0 or 1 (no NULLs)
SELECT is_readmitted_30, COUNT(*) AS cnt FROM diabetic_data_clean GROUP BY is_readmitted_30;

-- V-03  readmitted x is_readmitted_30 cross-check
SELECT readmitted, is_readmitted_30, COUNT(*) AS cnt
FROM diabetic_data_clean GROUP BY readmitted, is_readmitted_30 ORDER BY readmitted;

-- V-04  No NULL age_midpoints for known brackets
SELECT age, age_midpoint FROM diabetic_data_clean WHERE age_midpoint IS NULL GROUP BY age, age_midpoint;

-- V-05  Tier coverage (no NULLs)
SELECT medication_burden_tier,    COUNT(*) AS cnt FROM diabetic_data_clean GROUP BY medication_burden_tier;
SELECT diagnosis_complexity_tier, COUNT(*) AS cnt FROM diabetic_data_clean GROUP BY diagnosis_complexity_tier;

-- V-06  Excluded discharge IDs must be gone
SELECT COUNT(*) AS should_be_zero FROM diabetic_data_clean WHERE discharge_disposition_id IN (11,13,14,19,20,21);

-- V-07  View rows must equal base table rows (no JOIN fan-out)
SELECT
    (SELECT COUNT(*) FROM diabetic_data_clean)     AS base_rows,
    (SELECT COUNT(*) FROM vw_readmission_analysis) AS view_rows;

-- Indexes for JOIN, GROUP BY, and WHERE performance
CREATE INDEX idx_readmitted         ON diabetic_data_clean (readmitted(5));
CREATE INDEX idx_is_readmitted_30   ON diabetic_data_clean (is_readmitted_30);
CREATE INDEX idx_patient_nbr        ON diabetic_data_clean (patient_nbr);
CREATE INDEX idx_discharge_disp     ON diabetic_data_clean (discharge_disposition_id);
CREATE INDEX idx_admission_type     ON diabetic_data_clean (admission_type_id);
CREATE INDEX idx_admission_source   ON diabetic_data_clean (admission_source_id);
CREATE INDEX idx_diag_1             ON diabetic_data_clean (diag_1(10));

SHOW INDEXES FROM diabetic_data_clean;