-- =============================================
-- Author:		Sam Johnmeyer
-- Create date: 04/04/2019
-- Description:	2019 CMS HCC Risk Model. v23
-- =============================================

/***********************************************************************************************
INSTRUCTIONS.

BEFORE CONTINUTING. Please note that this code requires you to have already run the '(0) - Load Standard Tables' query using the same database. 
If you have not already done so, please run this code.

There are two inputs and two outputs in this code. The two inputs will require manual effort to create the first time you run this code. Assuming
you are able to create the persona and diag files correctly, the rest of the code should run without needing manual changes. 

Inputs:
1. PERSON file. See 'requirements' below. 
2. DIAG file. See 'requirements' below. 

Outputs:
1. dbo.Bene_Score_2019_v23. This is a single score for each beneficiary.
2. dbo.Bene_HCC_2019_v23. This is a list of all HCCs and interactions for each beneficiary. This is not a standard output of the CMS SAS model, but I 
					have found it to be useful when trying to figure out why a score isn't matching what CMS is showing. 
***********************************************************************************************/


/***********************************************************************************************
PERSON FILE REQUIREMENTS

CMS SAS code requires the Person file to have the following variables:
 *     :&IDVAR    - person ID variable (it is a macro parameter, HICNO  
 *                  for Medicare data)
 *     :DOB       - date of birth
 *     :SEX       - sex
 *     :OREC      - original reason for entitlement
 *     :LTIMCAID  - Medicaid dummy variable for LTI (payment year)
 *     :NEMCAID   - Medicaid dummy variable for new enrollees (payment
 *                  year)

 I am changing the logic slightly to require the following variables
 ----HICN. This can be any ID as long as you rename it  "HICN"...bene id, member id, actual HICN, MBI, whatever. Needs to be unique id for each beneficiary and needs to be named HICN
 ----DOB. in date format.  date of birth
 ----SEX. one character, 1=male; 2=female. For the record, I did not decide on this logic...CMS did. 
 ----OREC. one character. original reason for entitlement 0 - OLD AGE (OASI), 1 - DISABILITY (DIB), 2 – ESRD, 3 - BOTH DIB AND ESRD
 ----MEDICAID. one character. =1 if number of months in Medicaid in PAYMENT year >0, 0 otherwise.
			Instead of having LTIMCAID and NEMCAID I decided to just use one Medicaid field.
 ----MODEL. This refers to the risk adjustment model to be used for each beneficiary. The biggest difference between this code and the CMS SAS code 
			is that I am choosing a risk model for each beneficiary BEFORE calculating the risk score. The SAS version of the code calculates 9 risk scores 
			for each beneficiary and then allows you to choose one. Another key point is that this code only allows for the following model types
			----CN. Community.
			----CF. Full dual.
			----CP. Partial dual
			----I. Institutional.
			----E. New Enrollee.
			This code will not calculate scores for ESRD or SNP beneficiaries

If you only have Medicaid Dual Status Codes, these are the full vs partial mappings.
PARTIAL DUAL = 01,03,05,06
FULL DUAL = 02,04,08,10
---I pulled these down from version 10.3 of the Medicare Advantage & Prescription Drug Plans Plan Communications User Guide

***********************************************************************************************/


/***********************************************************************************************

DIAG FILE REQUIREMENTS. These are the same as the CMS requirements
DIAG file--a diagnosis file with at least one record per person-specific unique diagnosis.

---HICN (or other person identification variable that must be the same as in PERSON file)
				- person identifier of character or numeric type and unique to an individual
---DIAG. Diagnosis code, 7 character field, no periods, left justified. The user may include all diagnoses or
limit the codes to those used by the model. Codes should be to the greatest level of available
specificity. Diagnoses should be included only from acceptable sources, depending on whether you are using RAPS submission or encounter data.

***********************************************************************************************/

/***********************************************************************************************
CODE START
***********************************************************************************************/

USE [RISKADJUSTMENT] ----edit as needed


/***********************************************************************************************

DROPPING TABLES

***********************************************************************************************/
IF OBJECT_ID('dbo.person', 'U') IS NOT NULL DROP TABLE dbo.person
IF OBJECT_ID('dbo.diag', 'U') IS NOT NULL DROP TABLE dbo.diag
IF OBJECT_ID('dbo.person_2', 'U') IS NOT NULL DROP TABLE dbo.person_2
IF OBJECT_ID('dbo.table_1', 'U') IS NOT NULL DROP TABLE dbo.table_1
IF OBJECT_ID('dbo.table_2', 'U') IS NOT NULL DROP TABLE dbo.table_2
IF OBJECT_ID('dbo.table_3', 'U') IS NOT NULL DROP TABLE dbo.table_3
IF OBJECT_ID('dbo.HCC_output', 'U') IS NOT NULL DROP TABLE dbo.HCC_output

/***********************************************************************************************

PERSON TABLE SET-UP

***********************************************************************************************/

--dbo.person is REQUIRED in order for the risk model to run. see requirements above. one row per beneficiary
select HICN, DOB, SEX, OREC, MEDICAID, MODEL 
into dbo.person
from [dbo].[eligibility_table] --this depends on your internal data structure
where hicn is not null

---CHECK TO MAKE SURE THERE IS ONLY ONE ROW PER HICN BEFORE CONTINUING

/***********************************************************************************************

DIAGNOSIS TABLE SET-UP
There are a ton of ways to do this, depending on your objective. I am setting this up to show one, simple way to do so
In the following example I am going to calculate the risk score based on paid claims. I am also selecting distinct diag but that's just to reduce the number of rows.
No need to limit to valid beneficiaries since that happens in a few steps but you can if you want to
***********************************************************************************************/
---V23: EDS + RAPS IP
---note: I am bringing in EDS eligible paid claims and submitted RAPS IP diagnosis codes.
---note2: this requires EDS risk eligible logic.
---note3: raps provider types can be found here https://www.csscoperations.com/Internet/Cssc3.Nsf/files/2013_RA101ParticipantGuide_5CR_081513.pdf/$File/2013_RA101ParticipantGuide_5CR_081513.pdf
select * into dbo.diag from (
select distinct HICN, replace(DIAG, '.', '') as DIAG from [dbo.PAID_CLAIMS] where year(clm_thru_dt)=2018 and EDS_RiskEligible = 1 and diag is not null and hicn is not null union
select distinct HICN, replace(DIAG, '.', '') as DIAG from [dbo.RAPS_SUBMISSIONS] where year(clm_thru_dt)=2018 and Provider_type in ('01','02') and diag is not null and hicn is not null ) a



/***********************************************************************************************

PERSON FILE PREP.
----adding age and disabled

***********************************************************************************************/
select *, 
	FLOOR(DATEDIFF(DAY, DOB, '20190201') / 365.25) as Age, --age as of feb 1
	case when FLOOR(DATEDIFF(DAY, DOB, '20190201') / 365.25) < 65 and OREC <>0 then 1 else 0 end as Disabled
into dbo.person_2
from dbo.person

/***********************************************************************************************

DIAG TO HCC CROSSWALK. 

***********************************************************************************************/

select a.*,
	case when len(b.HCC)=3 then 'HCC'+ltrim(str(b.HCC))
	when len(b.HCC)=2 then 'HCC0'+ltrim(str(b.HCC))
	when len(b.HCC)=1 then 'HCC00'+ltrim(str(b.HCC)) end as HCC
into dbo.table_1
from dbo.diag a
left join dbo.cms_icd10_hcc_mapping_v23 b on a.diag=b.diag
where b.HCC is not null


/***********************************************************************************************

UNIQUE HCCS BY BENEFICIARY. I am using the Person file as the base of this file to ensure only beneficiaries in the person file get a record created. 
Also, I want to make sure every beneficiary has a row even if they don't have an HCC in this time period

***********************************************************************************************/
select a.HICN,
	max(case when HCC = 'HCC001' then 1 else 0 end) as HCC001,
	max(case when HCC = 'HCC002' then 1 else 0 end) as HCC002,
	max(case when HCC = 'HCC006' then 1 else 0 end) as HCC006,
	max(case when HCC = 'HCC008' then 1 else 0 end) as HCC008,
	max(case when HCC = 'HCC009' then 1 else 0 end) as HCC009,
	max(case when HCC = 'HCC010' then 1 else 0 end) as HCC010,
	max(case when HCC = 'HCC011' then 1 else 0 end) as HCC011,
	max(case when HCC = 'HCC012' then 1 else 0 end) as HCC012,
	max(case when HCC = 'HCC017' then 1 else 0 end) as HCC017,
	max(case when HCC = 'HCC018' then 1 else 0 end) as HCC018,
	max(case when HCC = 'HCC019' then 1 else 0 end) as HCC019,
	max(case when HCC = 'HCC021' then 1 else 0 end) as HCC021,
	max(case when HCC = 'HCC022' then 1 else 0 end) as HCC022,
	max(case when HCC = 'HCC023' then 1 else 0 end) as HCC023,
	max(case when HCC = 'HCC027' then 1 else 0 end) as HCC027,
	max(case when HCC = 'HCC028' then 1 else 0 end) as HCC028,
	max(case when HCC = 'HCC029' then 1 else 0 end) as HCC029,
	max(case when HCC = 'HCC033' then 1 else 0 end) as HCC033,
	max(case when HCC = 'HCC034' then 1 else 0 end) as HCC034,
	max(case when HCC = 'HCC035' then 1 else 0 end) as HCC035,
	max(case when HCC = 'HCC039' then 1 else 0 end) as HCC039,
	max(case when HCC = 'HCC040' then 1 else 0 end) as HCC040,
	max(case when HCC = 'HCC046' then 1 else 0 end) as HCC046,
	max(case when HCC = 'HCC047' then 1 else 0 end) as HCC047,
	max(case when HCC = 'HCC048' then 1 else 0 end) as HCC048,
	max(case when HCC = 'HCC054' then 1 else 0 end) as HCC054,
	max(case when HCC = 'HCC055' then 1 else 0 end) as HCC055,
	max(case when HCC = 'HCC056' then 1 else 0 end) as HCC056,
	max(case when HCC = 'HCC057' then 1 else 0 end) as HCC057,
	max(case when HCC = 'HCC058' then 1 else 0 end) as HCC058,
	max(case when HCC = 'HCC059' then 1 else 0 end) as HCC059,
	max(case when HCC = 'HCC060' then 1 else 0 end) as HCC060,
	max(case when HCC = 'HCC070' then 1 else 0 end) as HCC070,
	max(case when HCC = 'HCC071' then 1 else 0 end) as HCC071,
	max(case when HCC = 'HCC072' then 1 else 0 end) as HCC072,
	max(case when HCC = 'HCC073' then 1 else 0 end) as HCC073,
	max(case when HCC = 'HCC074' then 1 else 0 end) as HCC074,
	max(case when HCC = 'HCC075' then 1 else 0 end) as HCC075,
	max(case when HCC = 'HCC076' then 1 else 0 end) as HCC076,
	max(case when HCC = 'HCC077' then 1 else 0 end) as HCC077,
	max(case when HCC = 'HCC078' then 1 else 0 end) as HCC078,
	max(case when HCC = 'HCC079' then 1 else 0 end) as HCC079,
	max(case when HCC = 'HCC080' then 1 else 0 end) as HCC080,
	max(case when HCC = 'HCC082' then 1 else 0 end) as HCC082,
	max(case when HCC = 'HCC083' then 1 else 0 end) as HCC083,
	max(case when HCC = 'HCC084' then 1 else 0 end) as HCC084,
	max(case when HCC = 'HCC085' then 1 else 0 end) as HCC085,
	max(case when HCC = 'HCC086' then 1 else 0 end) as HCC086,
	max(case when HCC = 'HCC087' then 1 else 0 end) as HCC087,
	max(case when HCC = 'HCC088' then 1 else 0 end) as HCC088,
	max(case when HCC = 'HCC096' then 1 else 0 end) as HCC096,
	max(case when HCC = 'HCC099' then 1 else 0 end) as HCC099,
	max(case when HCC = 'HCC100' then 1 else 0 end) as HCC100,
	max(case when HCC = 'HCC103' then 1 else 0 end) as HCC103,
	max(case when HCC = 'HCC104' then 1 else 0 end) as HCC104,
	max(case when HCC = 'HCC106' then 1 else 0 end) as HCC106,
	max(case when HCC = 'HCC107' then 1 else 0 end) as HCC107,
	max(case when HCC = 'HCC108' then 1 else 0 end) as HCC108,
	max(case when HCC = 'HCC110' then 1 else 0 end) as HCC110,
	max(case when HCC = 'HCC111' then 1 else 0 end) as HCC111,
	max(case when HCC = 'HCC112' then 1 else 0 end) as HCC112,
	max(case when HCC = 'HCC114' then 1 else 0 end) as HCC114,
	max(case when HCC = 'HCC115' then 1 else 0 end) as HCC115,
	max(case when HCC = 'HCC122' then 1 else 0 end) as HCC122,
	max(case when HCC = 'HCC124' then 1 else 0 end) as HCC124,
	max(case when HCC = 'HCC134' then 1 else 0 end) as HCC134,
	max(case when HCC = 'HCC135' then 1 else 0 end) as HCC135,
	max(case when HCC = 'HCC136' then 1 else 0 end) as HCC136,
	max(case when HCC = 'HCC137' then 1 else 0 end) as HCC137,
	max(case when HCC = 'HCC138' then 1 else 0 end) as HCC138,
	max(case when HCC = 'HCC157' then 1 else 0 end) as HCC157,
	max(case when HCC = 'HCC158' then 1 else 0 end) as HCC158,
	max(case when HCC = 'HCC161' then 1 else 0 end) as HCC161,
	max(case when HCC = 'HCC162' then 1 else 0 end) as HCC162,
	max(case when HCC = 'HCC166' then 1 else 0 end) as HCC166,
	max(case when HCC = 'HCC167' then 1 else 0 end) as HCC167,
	max(case when HCC = 'HCC169' then 1 else 0 end) as HCC169,
	max(case when HCC = 'HCC170' then 1 else 0 end) as HCC170,
	max(case when HCC = 'HCC173' then 1 else 0 end) as HCC173,
	max(case when HCC = 'HCC176' then 1 else 0 end) as HCC176,
	max(case when HCC = 'HCC186' then 1 else 0 end) as HCC186,
	max(case when HCC = 'HCC188' then 1 else 0 end) as HCC188,
	max(case when HCC = 'HCC189' then 1 else 0 end) as HCC189
into dbo.table_2
from dbo.person_2 a
left join dbo.table_1 b on a.HICN=b.HICN
group by a.HICN;

/***********************************************************************************************

ADDITIONAL PREP
--bucketing beneficiaries into age ranges
--establishing hierarchies
--creating interactions
--developing unique lookup key. 

**One comment on OREC. I am changing OREC from 1 to 0 for all beneficiaries under age 65. This is because my code is setup to 
reference OREC for New Enrollees when determining which coefficients to use. However, if a beneficiary is 64, on the new enrollee model,
there is no value for OREC=1 in the standard weights table. The model only has "Non-Medicaid and Non-Originally Disabled", but I have seen 
60-64 year old beneficiaries in the MMR with OREC=1 on the new enrollee model. As a result, please bring in the CMS value for OREC
and I will adjust the value here so that all new enrollees under 65 are being scored on the correct model.
***********************************************************************************************/

select a.*, b.SEX, b.DOB, b.AGE, 
case when AGE<=64 and b.OREC=1 then 0 else b.OREC end as OREC,
b.Disabled, b.Model,
---female demo variable
f0_34 = case when AGE>0 and AGE <=34 and SEX=2 then 1 else 0 end,
f35_44 = case when AGE>34 and AGE <=44 and SEX=2 then 1 else 0 end,
f45_54 = case when AGE>44 and AGE <=54 and SEX=2 then 1 else 0 end,
f55_59 = case when AGE>54 and AGE <=59 and SEX=2 then 1 else 0 end,
f60_64 = case when AGE>59 and AGE <=63 and SEX=2 then 1 when AGE=64 and OREC<>0 and SEX=2 then 1 else 0 end,
f65 = case when Model='E' and AGE=65 and SEX=2 then 1 when AGE=64 and OREC=0 and SEX=2 then 1 else 0 end,
f66 = case when Model='E' and AGE=66 and SEX=2 then 1 else 0 end,
f67 = case when Model='E' and AGE=67 and SEX=2 then 1 else 0 end,
f68 = case when Model='E' and AGE=68 and SEX=2 then 1 else 0 end,
f69 = case when Model='E' and AGE=69 and SEX=2 then 1 else 0 end,
f65_69 = case when AGE>64 and AGE <=69 and SEX=2 then 1 else 0 end,
f70_74 = case when AGE>69 and AGE <=74 and SEX=2 then 1 else 0 end,
f75_79 = case when AGE>74 and AGE <=79 and SEX=2 then 1 else 0 end,
f80_84 = case when AGE>79 and AGE <=84 and SEX=2 then 1 else 0 end,
f85_89 = case when AGE>84 and AGE <=89 and SEX=2 then 1 else 0 end,
f90_94 = case when AGE>89 and AGE <=94 and SEX=2 then 1 else 0 end,
f95_gt = case when AGE>94 and SEX=2 then 1 else 0 end,
---male demo variable
m0_34 = case when AGE>0 and AGE <=34 and SEX=1 then 1 else 0 end,
m35_44 = case when AGE>34 and AGE <=44 and SEX=1 then 1 else 0 end,
m45_54 = case when AGE>44 and AGE <=54 and SEX=1 then 1 else 0 end,
m55_59 = case when AGE>54 and AGE <=59 and SEX=1 then 1 else 0 end,
m60_64 = case when AGE>59 and AGE <=63 and SEX=1 then 1 when AGE=64 and OREC<>0 and SEX=1 then 1 else 0 end, 
m65 = case when Model='E' and AGE=65 and SEX=1 then 1 when AGE=64 and OREC=0 and SEX=1 then 1 else 0 end, 
m66 = case when Model='E' and AGE=66 and SEX=1 then 1 else 0 end,
m67 = case when Model='E' and AGE=67 and SEX=1 then 1 else 0 end,
m68 = case when Model='E' and AGE=68 and SEX=1 then 1 else 0 end,
m69 = case when Model='E' and AGE=69 and SEX=1 then 1 else 0 end,
m65_69 = case when AGE>64 and AGE <=69 and SEX=1 then 1 else 0 end,
m70_74 = case when AGE>69 and AGE <=74 and SEX=1 then 1 else 0 end,
m75_79 = case when AGE>74 and AGE <=79 and SEX=1 then 1 else 0 end,
m80_84 = case when AGE>79 and AGE <=84 and SEX=1 then 1 else 0 end,
m85_89 = case when AGE>84 and AGE <=89 and SEX=1 then 1 else 0 end,
m90_94 = case when AGE>89 and AGE <=94 and SEX=1 then 1 else 0 end,
m95_gt = case when AGE>94 and SEX=1 then 1 else 0 end,
---preparing for hierarchies
case when HCC008=1 then 1 else 0 end as CC_08,
case when HCC009=1 then 1 else 0 end as CC_09,
case when HCC010=1 then 1 else 0 end as CC_10,
case when HCC011=1 then 1 else 0 end as CC_11,
case when HCC017=1 then 1 else 0 end as CC_17,
case when HCC018=1 then 1 else 0 end as CC_18,
case when HCC027=1 then 1 else 0 end as CC_27,
case when HCC028=1 then 1 else 0 end as CC_28,
case when HCC046=1 then 1 else 0 end as CC_46,
case when HCC054=1 then 1 else 0 end as CC_54,
case when HCC055=1 then 1 else 0 end as CC_55, ---new in v23
case when HCC057=1 then 1 else 0 end as CC_57,
case when HCC058=1 then 1 else 0 end as CC_58, ---new in v23
case when HCC059=1 then 1 else 0 end as CC_59, ---new in v23
case when HCC070=1 then 1 else 0 end as CC_70,
case when HCC071=1 then 1 else 0 end as CC_71,
case when HCC072=1 then 1 else 0 end as CC_72,
case when HCC082=1 then 1 else 0 end as CC_82,
case when HCC083=1 then 1 else 0 end as CC_83,
case when HCC086=1 then 1 else 0 end as CC_86,
case when HCC087=1 then 1 else 0 end as CC_87,
case when HCC099=1 then 1 else 0 end as CC_99,
case when HCC103=1 then 1 else 0 end as CC_103,
case when HCC106=1 then 1 else 0 end as CC_106,
case when HCC107=1 then 1 else 0 end as CC_107,
case when HCC110=1 then 1 else 0 end as CC_110,
case when HCC111=1 then 1 else 0 end as CC_111,
case when HCC114=1 then 1 else 0 end as CC_114,
case when HCC134=1 then 1 else 0 end as CC_134,
case when HCC135=1 then 1 else 0 end as CC_135,
case when HCC136=1 then 1 else 0 end as CC_136,
case when HCC137=1 then 1 else 0 end as CC_137, ---new in v23
case when HCC157=1 then 1 else 0 end as CC_157,
case when HCC158=1 then 1 else 0 end as CC_158,
case when HCC166=1 then 1 else 0 end as CC_166,
----interactions
hcc47_gcancer = case when HCC047=1 and (HCC008+HCC009+HCC010+HCC011+HCC012) >0 then 1 else 0 end,
hcc85_gdiabetesmellit = case when HCC085=1 and (HCC017+HCC018+HCC019) >0 then 1 else 0 end,
hcc85_gcopdcf = case when HCC085=1 and (HCC110+HCC111+HCC112) >0 then 1 else 0 end,
HCC85_gRenal_V23 = case when HCC085=1 and (HCC134+HCC135+HCC136+HCC137+HCC138) >0 then 1 else 0 end,
grespdepandarre_gcopdcf = case when (HCC082+HCC083+HCC084) >0 and (HCC110+HCC111+HCC112) >0 then 1 else 0 end,
hcc85_hcc96 = case when HCC085=1 and HCC096=1 then 1 else 0 end,
disable_substAbuse_psych_V23 = case when (HCC054+HCC055+HCC056) > 0 and (HCC057+HCC058+HCC059+HCC060) > 0 and Disabled = 1 then 1 else 0 end,
ltimcaid = case when Medicaid=1 and Model = 'I' then 1 else 0 end,
origds = 0, ---this is in the model, but there are no coefficients so I am zeroing it out
SEPSIS_PRESSURE_ULCER = case when HCC002=1 and (HCC157+HCC158) > 0 then 1 else 0 end,
SEPSIS_ARTIF_OPENINGS = case when HCC002=1 and HCC188=1 then 1 else 0 end,
ART_OPENINGS_PRESS_ULCER = case when HCC188=1 and (HCC157+HCC158) > 0 then 1 else 0 end,
gCopdCF_ASP_SPEC_B_PNEUM = case when HCC114=1 and (HCC110+HCC111+HCC112) >0 then 1 else 0 end,
ASP_SPEC_B_PNEUM_PRES_ULC = case when HCC114=1 and (HCC157+HCC158) > 0 then 1 else 0 end,
SEPSIS_ASP_SPEC_BACT_PNEUM = case when HCC002=1 and HCC114=1 then 1 else 0 end,
SCHIZOPHRENIA_gCopdCF = case when HCC057=1 and (HCC110+HCC111+HCC112) >0 then 1 else 0 end,
SCHIZOPHRENIA_CHF = case when HCC057=1 and HCC085=1 then 1 else 0 end,
SCHIZOPHRENIA_SEIZURES = case when HCC057=1 and HCC079=1 then 1 else 0 end,
DISABLED_HCC85 = case when Disabled=1 and HCC085=1 then 1 else 0 end,
DISABLED_PRESSURE_ULCER = case when Disabled=1 and (HCC157+HCC158) > 0 then 1 else 0 end,
DISABLED_HCC161 = case when Disabled=1 and HCC161=1 then 1 else 0 end,
DISABLED_HCC39 = case when Disabled=1 and HCC039=1 then 1 else 0 end,
DISABLED_HCC77 = case when Disabled=1 and HCC077=1 then 1 else 0 end,
DISABLED_HCC6 = case when Disabled=1 and HCC006=1 then 1 else 0 end,
chf_gcopdcf = case when HCC085=1 and (HCC110+HCC111+HCC112) >0 then 1 else 0 end, ---same logic as HCC85_gcopdcf
gcopdcf_card_resp_fail = case when (HCC082+HCC083+HCC084) >0 and (HCC110+HCC111+HCC112) >0 then 1 else 0 end, ---same logic as grespdepandarre_gcopdcf
diabetes_chf = case when HCC085=1 and (HCC017+HCC018+HCC019) >0 then 1 else 0 end, ---same logic as hcc85_gdiabetesmellit
originallydisabled_female = case when OREC=1 and SEX=2 then 1 else 0 end,
originallydisabled_male = case when OREC=1 and SEX=1 then 1 else 0 end,
----this section is creating the lookup variable which is where this diverages from the CMS SAS program. one lookup key per beneficiary
CASE WHEN MODEL IN ('CN','CP','CF') THEN (CONVERT(VARCHAR,MODEL) + CONVERT(VARCHAR,DISABLED))
		WHEN MODEL = 'I' THEN 'I'
		WHEN MODEL = 'E' AND AGE<=64 THEN (CONVERT(VARCHAR,MODEL) + CONVERT(VARCHAR,MEDICAID) + '0') ---this is the OREC change I mentioned in the comment above
		WHEN MODEL = 'E' AND AGE >64 THEN (CONVERT(VARCHAR,MODEL) + CONVERT(VARCHAR,MEDICAID) + CONVERT(VARCHAR,OREC)) END AS LOOKUP_KEY,
CMS_RISK_SCORE = CAST(0 AS FLOAT),
DEMO_RISK_SCORE = CAST(0 AS FLOAT)
into dbo.table_3
from dbo.table_2 a
left join dbo.person_2 b on a.HICN=b.HICN
order by HICN;

 
/***********************************************************************************************\

HIERARCHIES

\***********************************************************************************************/

update dbo.table_3 set HCC009=0 where CC_08=1
update dbo.table_3 set HCC010=0 where CC_08=1
update dbo.table_3 set HCC011=0 where CC_08=1
update dbo.table_3 set HCC012=0 where CC_08=1

update dbo.table_3 set HCC010=0 where CC_09=1
update dbo.table_3 set HCC011=0 where CC_09=1
update dbo.table_3 set HCC012=0 where CC_09=1

update dbo.table_3 set HCC011=0 where CC_10=1
update dbo.table_3 set HCC012=0 where CC_10=1

update dbo.table_3 set HCC012=0 where CC_11=1

update dbo.table_3 set HCC018=0 where CC_17=1
update dbo.table_3 set HCC019=0 where CC_17=1

update dbo.table_3 set HCC019=0 where CC_18=1

update dbo.table_3 set HCC028=0 where CC_27=1
update dbo.table_3 set HCC029=0 where CC_27=1
update dbo.table_3 set HCC080=0 where CC_27=1

update dbo.table_3 set HCC029=0 where CC_28=1

update dbo.table_3 set HCC048=0 where CC_46=1

update dbo.table_3 set HCC055=0 where CC_54=1
update dbo.table_3 set HCC056=0 where CC_54=1

update dbo.table_3 set HCC056=0 where CC_55=1

update dbo.table_3 set HCC058=0 where CC_57=1
update dbo.table_3 set HCC059=0 where CC_57=1
update dbo.table_3 set HCC060=0 where CC_57=1

update dbo.table_3 set HCC059=0 where CC_58=1
update dbo.table_3 set HCC060=0 where CC_58=1

update dbo.table_3 set HCC060=0 where CC_59=1

update dbo.table_3 set HCC071=0 where CC_70=1
update dbo.table_3 set HCC072=0 where CC_70=1
update dbo.table_3 set HCC103=0 where CC_70=1
update dbo.table_3 set HCC104=0 where CC_70=1
update dbo.table_3 set HCC169=0 where CC_70=1

update dbo.table_3 set HCC072=0 where CC_71=1
update dbo.table_3 set HCC104=0 where CC_71=1
update dbo.table_3 set HCC169=0 where CC_71=1

update dbo.table_3 set HCC169=0 where CC_72=1

update dbo.table_3 set HCC083=0 where CC_82=1
update dbo.table_3 set HCC084=0 where CC_82=1

update dbo.table_3 set HCC084=0 where CC_83=1

update dbo.table_3 set HCC087=0 where CC_86=1
update dbo.table_3 set HCC088=0 where CC_86=1

update dbo.table_3 set HCC088=0 where CC_87=1

update dbo.table_3 set HCC100=0 where CC_99=1

update dbo.table_3 set HCC104=0 where CC_103=1

update dbo.table_3 set HCC107=0 where CC_106=1
update dbo.table_3 set HCC108=0 where CC_106=1
update dbo.table_3 set HCC161=0 where CC_106=1
update dbo.table_3 set HCC189=0 where CC_106=1

update dbo.table_3 set HCC108=0 where CC_107=1

update dbo.table_3 set HCC111=0 where CC_110=1
update dbo.table_3 set HCC112=0 where CC_110=1

update dbo.table_3 set HCC112=0 where CC_111=1

update dbo.table_3 set HCC115=0 where CC_114=1

update dbo.table_3 set HCC135=0 where CC_134=1
update dbo.table_3 set HCC136=0 where CC_134=1
update dbo.table_3 set HCC137=0 where CC_134=1
update dbo.table_3 set HCC138=0 where CC_134=1

update dbo.table_3 set HCC136=0 where CC_135=1
update dbo.table_3 set HCC137=0 where CC_135=1
update dbo.table_3 set HCC138=0 where CC_135=1

update dbo.table_3 set HCC137=0 where CC_136=1
update dbo.table_3 set HCC138=0 where CC_136=1

update dbo.table_3 set HCC138=0 where CC_137=1

update dbo.table_3 set HCC158=0 where CC_157=1
update dbo.table_3 set HCC161=0 where CC_157=1

update dbo.table_3 set HCC161=0 where CC_158=1

update dbo.table_3 set HCC080=0 where CC_166=1
update dbo.table_3 set HCC167=0 where CC_166=1

/***********************************************************************************************\

NOW CALCULATING THE FINAL RISK SCORE. Once again, this is one score per beneficiary not 9 scores per beneficiary like in the CMS SAS model.

\***********************************************************************************************/

UPDATE dbo.table_3
SET CMS_RISK_SCORE = ROUND((COALESCE(B_f0_34*f0_34 + 	B_f35_44*f35_44 + 	B_f45_54*f45_54 + 	B_f55_59*f55_59 + 	B_f60_64*f60_64 + 	B_f65*f65 + 	B_f66*f66 + 	B_f67*f67 + 	B_f68*f68 + 	B_f69*f69 + 	B_f65_69*f65_69 + 	B_f70_74*f70_74 + 	B_f75_79*f75_79 + 	B_f80_84*f80_84 + 	B_f85_89*f85_89 + 	B_f90_94*f90_94 + 	B_f95_gt*f95_gt + 	B_m0_34*m0_34 + 	B_m35_44*m35_44 + 	B_m45_54*m45_54 + 	B_m55_59*m55_59 + 	B_m60_64*m60_64 + 	B_m65*m65 + 	B_m66*m66 + 	B_m67*m67 + 	B_m68*m68 + 	B_m69*m69 + 	B_m65_69*m65_69 + 	B_m70_74*m70_74 + 	B_m75_79*m75_79 + 	B_m80_84*m80_84 + 	B_m85_89*m85_89 + 	B_m90_94*m90_94 + 	B_m95_gt*m95_gt + 	B_originallydisabled_female*originallydisabled_female + 	B_originallydisabled_male*originallydisabled_male + 	B_HCC001*HCC001 + 	B_HCC002*HCC002 + 	B_HCC006*HCC006 + 	B_HCC008*HCC008 + 	B_HCC009*HCC009 + 	B_HCC010*HCC010 + 	B_HCC011*HCC011 + 	B_HCC012*HCC012 + 	B_HCC017*HCC017 + 	B_HCC018*HCC018 + 	B_HCC019*HCC019 + 	B_HCC021*HCC021 + 	B_HCC022*HCC022 + 	B_HCC023*HCC023 + 	B_HCC027*HCC027 + 	B_HCC028*HCC028 + 	B_HCC029*HCC029 + 	B_HCC033*HCC033 + 	B_HCC034*HCC034 + 	B_HCC035*HCC035 + 	B_HCC039*HCC039 + 	B_HCC040*HCC040 + 	B_HCC046*HCC046 + 	B_HCC047*HCC047 + 	B_HCC048*HCC048 + 	B_HCC054*HCC054 + 	B_HCC055*HCC055 + 	B_HCC056*HCC056 + 	B_HCC057*HCC057 + 	B_HCC058*HCC058 + 	B_HCC059*HCC059 + 	B_HCC060*HCC060 + 	B_HCC070*HCC070 + 	B_HCC071*HCC071 + 	B_HCC072*HCC072 + 	B_HCC073*HCC073 + 	B_HCC074*HCC074 + 	B_HCC075*HCC075 + 	B_HCC076*HCC076 + 	B_HCC077*HCC077 + 	B_HCC078*HCC078 + 	B_HCC079*HCC079 + 	B_HCC080*HCC080 + 	B_HCC082*HCC082 + 	B_HCC083*HCC083 + 	B_HCC084*HCC084 + 	B_HCC085*HCC085 + 	B_HCC086*HCC086 + 	B_HCC087*HCC087 + 	B_HCC088*HCC088 + 	B_HCC096*HCC096 + 	B_HCC099*HCC099 + 	B_HCC100*HCC100 + 	B_HCC103*HCC103 + 	B_HCC104*HCC104 + 	B_HCC106*HCC106 + 	B_HCC107*HCC107 + 	B_HCC108*HCC108 + 	B_HCC110*HCC110 + 	B_HCC111*HCC111 + 	B_HCC112*HCC112 + 	B_HCC114*HCC114 + 	B_HCC115*HCC115 + 	B_HCC122*HCC122 + 	B_HCC124*HCC124 + 	B_HCC134*HCC134 + 	B_HCC135*HCC135 + 	B_HCC136*HCC136 + 	B_HCC137*HCC137 + 	B_HCC138*HCC138 + 	B_HCC157*HCC157 + 	B_HCC158*HCC158 + 	B_HCC161*HCC161 + 	B_HCC162*HCC162 + 	B_HCC166*HCC166 + 	B_HCC167*HCC167 + 	B_HCC169*HCC169 + 	B_HCC170*HCC170 + 	B_HCC173*HCC173 + 	B_HCC176*HCC176 + 	B_HCC186*HCC186 + 	B_HCC188*HCC188 + 	B_HCC189*HCC189 + 	B_HCC47_gCancer*HCC47_gCancer + 	B_HCC85_gDiabetesMellit*HCC85_gDiabetesMellit + 	B_HCC85_gCopdCF*HCC85_gCopdCF + 	B_HCC85_gRenal_V23*HCC85_gRenal_V23 + 	B_grespDepandArre_gCopdCF*grespDepandArre_gCopdCF + 	B_HCC85_HCC96*HCC85_HCC96 + 	B_disable_substAbuse_psych_V23*disable_substAbuse_psych_V23 + 	B_LTIMCAID*LTIMCAID + 	B_ORIGDS*ORIGDS + 	B_DISABLED_HCC85*DISABLED_HCC85 + 	B_DISABLED_PRESSURE_ULCER*DISABLED_PRESSURE_ULCER + 	B_DISABLED_HCC161*DISABLED_HCC161 + 	B_DISABLED_HCC39*DISABLED_HCC39 + 	B_DISABLED_HCC77*DISABLED_HCC77 + 	B_DISABLED_HCC6*DISABLED_HCC6 + 	B_CHF_gCopdCF*CHF_gCopdCF + 	B_gCopdCF_CARD_RESP_FAIL*gCopdCF_CARD_RESP_FAIL + 	B_SEPSIS_PRESSURE_ULCER*SEPSIS_PRESSURE_ULCER + 	B_SEPSIS_ARTIF_OPENINGS*SEPSIS_ARTIF_OPENINGS + 	B_ART_OPENINGS_PRESS_ULCER*ART_OPENINGS_PRESS_ULCER + 	B_DIABETES_CHF*DIABETES_CHF + 	B_gCopdCF_ASP_SPEC_B_PNEUM*gCopdCF_ASP_SPEC_B_PNEUM + 	B_ASP_SPEC_B_PNEUM_PRES_ULC*ASP_SPEC_B_PNEUM_PRES_ULC + 	B_SEPSIS_ASP_SPEC_BACT_PNEUM*SEPSIS_ASP_SPEC_BACT_PNEUM + 	B_SCHIZOPHRENIA_gCopdCF*SCHIZOPHRENIA_gCopdCF + 	B_SCHIZOPHRENIA_CHF*SCHIZOPHRENIA_CHF + 	B_SCHIZOPHRENIA_SEIZURES*SCHIZOPHRENIA_SEIZURES,0)
								)* 0.941/1.038,3) ---coding intensity and normalization figures for 2019 v23 model. From 2019 final call letter.
FROM dbo.table_3 A CROSS JOIN dbo.CMS_WEIGHTS_2019_V23 B
WHERE	( A.LOOKUP_KEY = B.LOOKUP_KEY)

/***********************************************************************************************\

SECOND OUTPUT TABLE. This is not in the CMS SAS model, but I think it is useful. This is a list of HCCs for each beneficiary

\***********************************************************************************************/
SELECT HICN, Cname HCC, data 
into dbo.HCC_output
from dbo.table_3
CROSS APPLY ( 
    VALUES
('f0_34',f0_34),	('f35_44',f35_44),	('f45_54',f45_54),	('f55_59',f55_59),	('f60_64',f60_64),	('f65',f65),	('f66',f66),	('f67',f67),	('f68',f68),	('f69',f69),	('f65_69',f65_69),	('f70_74',f70_74),	('f75_79',f75_79),	('f80_84',f80_84),	('f85_89',f85_89),	('f90_94',f90_94),	('f95_gt',f95_gt),	('m0_34',m0_34),	('m35_44',m35_44),	('m45_54',m45_54),	('m55_59',m55_59),	('m60_64',m60_64),	('m65',m65),	('m66',m66),	('m67',m67),	('m68',m68),	('m69',m69),	('m65_69',m65_69),	('m70_74',m70_74),	('m75_79',m75_79),	('m80_84',m80_84),	('m85_89',m85_89),	('m90_94',m90_94),	('m95_gt',m95_gt),	('originallydisabled_female',originallydisabled_female),	('originallydisabled_male',originallydisabled_male),	('HCC001',HCC001),	('HCC002',HCC002),	('HCC006',HCC006),	('HCC008',HCC008),	('HCC009',HCC009),	('HCC010',HCC010),	('HCC011',HCC011),	('HCC012',HCC012),	('HCC017',HCC017),	('HCC018',HCC018),	('HCC019',HCC019),	('HCC021',HCC021),	('HCC022',HCC022),	('HCC023',HCC023),	('HCC027',HCC027),	('HCC028',HCC028),	('HCC029',HCC029),	('HCC033',HCC033),	('HCC034',HCC034),	('HCC035',HCC035),	('HCC039',HCC039),	('HCC040',HCC040),	('HCC046',HCC046),	('HCC047',HCC047),	('HCC048',HCC048),	('HCC054',HCC054),	('HCC055',HCC055),	('HCC056',HCC056),	('HCC057',HCC057),	('HCC058',HCC058),	('HCC059',HCC059),	('HCC060',HCC060),	('HCC070',HCC070),	('HCC071',HCC071),	('HCC072',HCC072),	('HCC073',HCC073),	('HCC074',HCC074),	('HCC075',HCC075),	('HCC076',HCC076),	('HCC077',HCC077),	('HCC078',HCC078),	('HCC079',HCC079),	('HCC080',HCC080),	('HCC082',HCC082),	('HCC083',HCC083),	('HCC084',HCC084),	('HCC085',HCC085),	('HCC086',HCC086),	('HCC087',HCC087),	('HCC088',HCC088),	('HCC096',HCC096),	('HCC099',HCC099),	('HCC100',HCC100),	('HCC103',HCC103),	('HCC104',HCC104),	('HCC106',HCC106),	('HCC107',HCC107),	('HCC108',HCC108),	('HCC110',HCC110),	('HCC111',HCC111),	('HCC112',HCC112),	('HCC114',HCC114),	('HCC115',HCC115),	('HCC122',HCC122),	('HCC124',HCC124),	('HCC134',HCC134),	('HCC135',HCC135),	('HCC136',HCC136),	('HCC137',HCC137),	('HCC138',HCC138),	('HCC157',HCC157),	('HCC158',HCC158),	('HCC161',HCC161),	('HCC162',HCC162),	('HCC166',HCC166),	('HCC167',HCC167),	('HCC169',HCC169),	('HCC170',HCC170),	('HCC173',HCC173),	('HCC176',HCC176),	('HCC186',HCC186),	('HCC188',HCC188),	('HCC189',HCC189),	('HCC47_gCancer',HCC47_gCancer),	('HCC85_gDiabetesMellit',HCC85_gDiabetesMellit),	('HCC85_gCopdCF',HCC85_gCopdCF),	('HCC85_gRenal_V23',HCC85_gRenal_V23),	('grespDepandArre_gCopdCF',grespDepandArre_gCopdCF),	('HCC85_HCC96',HCC85_HCC96),	('disable_substAbuse_psych_V23',disable_substAbuse_psych_V23),	('LTIMCAID',LTIMCAID),	('ORIGDS',ORIGDS),	('DISABLED_HCC85',DISABLED_HCC85),	('DISABLED_PRESSURE_ULCER',DISABLED_PRESSURE_ULCER),	('DISABLED_HCC161',DISABLED_HCC161),	('DISABLED_HCC39',DISABLED_HCC39),	('DISABLED_HCC77',DISABLED_HCC77),	('DISABLED_HCC6',DISABLED_HCC6),	('CHF_gCopdCF',CHF_gCopdCF),	('gCopdCF_CARD_RESP_FAIL',gCopdCF_CARD_RESP_FAIL),	('SEPSIS_PRESSURE_ULCER',SEPSIS_PRESSURE_ULCER),	('SEPSIS_ARTIF_OPENINGS',SEPSIS_ARTIF_OPENINGS),	('ART_OPENINGS_PRESS_ULCER',ART_OPENINGS_PRESS_ULCER),	('DIABETES_CHF',DIABETES_CHF),	('gCopdCF_ASP_SPEC_B_PNEUM',gCopdCF_ASP_SPEC_B_PNEUM),	('ASP_SPEC_B_PNEUM_PRES_ULC',ASP_SPEC_B_PNEUM_PRES_ULC),	('SEPSIS_ASP_SPEC_BACT_PNEUM',SEPSIS_ASP_SPEC_BACT_PNEUM),	('SCHIZOPHRENIA_gCopdCF',SCHIZOPHRENIA_gCopdCF),	('SCHIZOPHRENIA_CHF',SCHIZOPHRENIA_CHF),	('SCHIZOPHRENIA_SEIZURES',SCHIZOPHRENIA_SEIZURES)	) ca (cname, data)
where data <> 0

/***********************************************************************************************\

FINAL STEP: RENAMING OUTPUT TABLES.

\***********************************************************************************************/
IF OBJECT_ID('dbo.Bene_HCC_2019_v23', 'U') IS NOT NULL DROP TABLE dbo.Bene_HCC_2019_v23
IF OBJECT_ID('dbo.Bene_Score_2019_v23', 'U') IS NOT NULL DROP TABLE dbo.Bene_Score_2019_v23
select * into dbo.Bene_HCC_2019_v23 from dbo.HCC_output
select HICN, CMS_RISK_SCORE into dbo.Bene_Score_2019_v23 from dbo.table_3


IF OBJECT_ID('dbo.diag', 'U') IS NOT NULL DROP TABLE dbo.diag
IF OBJECT_ID('dbo.person', 'U') IS NOT NULL DROP TABLE dbo.person
IF OBJECT_ID('dbo.person_2', 'U') IS NOT NULL DROP TABLE dbo.person_2
IF OBJECT_ID('dbo.table_1', 'U') IS NOT NULL DROP TABLE dbo.table_1
IF OBJECT_ID('dbo.table_2', 'U') IS NOT NULL DROP TABLE dbo.table_2
IF OBJECT_ID('dbo.table_3', 'U') IS NOT NULL DROP TABLE dbo.table_3
IF OBJECT_ID('dbo.HCC_output', 'U') IS NOT NULL DROP TABLE dbo.HCC_output

/***********************************************************************************************\
END CODE. It has been a pleasure.
\***********************************************************************************************/