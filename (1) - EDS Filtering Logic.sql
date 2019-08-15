/***********************************************************************************************
NOTES

---this code requires you to create dbo.MEDICARE_CPT_HCPCS_LIST before continuing. Please create this table if you have not done so already
---this is the document I used to create this logic. It is from 2015 but, to my knowledge, it is still accurate as of 2019
https://www.csscoperations.com/internet/cssc3.nsf/files/Final%20Industry%20Memo%20Medicare%20Filtering%20Logic%2012%2022%2015.pdf/$FIle/Final%20Industry%20Memo%20Medicare%20Filtering%20Logic%2012%2022%2015.pdf
---thoughout this code I am using the acronym EDS instead of EDPS. I have seen both used by different parties and I think EDS sounds better....so....whatever
---I am setting up this query in a pretty basic way...I am isolating claims that are eligible to be submitted via EDS. At the end, you'll have a 
long list of claims. You should be submitting all diagnosis codes from these claims. 
---where possible I am using RESDAC field names
---I'm also assuming that the claim table is final action throughout. If yours is not final action, you'll need to limit accordingly
***********************************************************************************************/

/***********************************************************************************************
BEGIN CODE.
***********************************************************************************************/

USE [RISKADJUSTMENT] ----edit as needed

/***********************************************************************************************

DROPPING TABLES

***********************************************************************************************/
IF OBJECT_ID('dbo.EDS_PHYS', 'U') IS NOT NULL DROP TABLE dbo.EDS_PHYS
IF OBJECT_ID('dbo.EDS_IP', 'U') IS NOT NULL DROP TABLE dbo.EDS_IP
IF OBJECT_ID('dbo.EDS_OP', 'U') IS NOT NULL DROP TABLE dbo.EDS_OP
IF OBJECT_ID('dbo.EDS_ALL', 'U') IS NOT NULL DROP TABLE dbo.EDS_ALL

/***********************************************************************************************

EDS PHYSICIAN

Per CMS:
Professional encounter data records are encounters, or related chart review records, where Part B
items and services have been provided. These items and services are provided by physicians,
non-physician practitioners (NPPs), and other Part B suppliers, and are submitted in an 837P
format. CMS will use CPT/HCPCS codes when filtering these encounters and chart review
records to identify risk adjustment eligible diagnoses. When filtering encounters and chart
review records, CMS will not use on the specialty code(s) associated with each NPI. 

CMS will select encounter data records with service “through dates” in the data collection year,
e.g., 2014 dates for PY 2015. Using the most recent version of a professional encounter data
record accepted by EDPS (i.e., a record that has passed system edits), CMS will evaluate the
accepted lines on the record to determine if the CPT/HCPCS codes are on the acceptable
Medicare Risk Adjustment CPT/HCPCS list (also referred to as the “Medicare CPT/HCPCS
list”). If there is an acceptable CPT/HCPCS code on at least one accepted line on the record,
CMS will use all the header diagnoses on that record. If there are no acceptable CPT/HCPCS
codes on any of the lines on the record, then CMS will not use any of the diagnoses on the record
for risk adjustment. CMS will use this process both for records that report an encounter and
associated chart review records. 

---the 'WHERE' clause is where things get tricky. we need to limit to just physician/carrier/837/whatever 
your organization calls it claims. in this example I am using CLM_TYPE_CD = 4700 based on the outpatient encounter data dictionary
published by RESDAC. In practice, I haven't used this dataset so I can't say if this is an accurate way to do it. Regardless,
the end goal is to get a list of unique physician claims that have at least one qualifying CPT/HCPCS code.

https://www.resdac.org/sites/resdac.umn.edu/files/Claim%20Type%20Code%20Table_0.txt

***********************************************************************************************/

select distinct a.CLM_CNTL_NUM
into dbo.EDS_PHYS
from dbo.CLAIMS a ---edit to fit your data
join dbo.MEDICARE_CPT_HCPCS_LIST b on a.HCPCS_CD=b.HCPCS_CPT_CODE and year(a.CLM_THRU_DT)=b.CY
where a.CLM_TYPE_CD = '4700' ---physician claims only
---also consider limiting to only a specific year depending on the size of you dataset.

/***********************************************************************************************

EDS INPATIENT

For IP filtering, we need type of bill. Per RESDAC The type of bill is the concatenation of two variables: 
-facility type (CLM_FAC_TYPE_CD) 
-service classification type (CLM_SRVC_CLSFCTN_TYPE_CD).
 Note that sometimes 3 variables are used for “type of bill”, where the 3rd digit is the claim frequency code (CLM_FREQ_CD) so you
 could also do left(type_of_bill,2) in ('11','41') if your data is setup that way

***********************************************************************************************/

select distinct CLM_CNTL_NUM
into dbo.EDS_IP
from dbo.CLAIMS ---edit to fit your data
where CLM_FAC_TYPE_CD+CLM_SRVC_CLSFCTN_TYPE_CD in ('11','41') ---if your data has TOB

/***********************************************************************************************

EDS OUTPATIENT

---combination of PHYS and IP. Needs to have at least one CPT/HCPCS in the list and TOB needs to start with one of the 8 possibilities

***********************************************************************************************/
select distinct a.CLM_CNTL_NUM
into dbo.EDS_OP
from dbo.CLAIMS a ---edit to fit your data
join dbo.MEDICARE_CPT_HCPCS_LIST b on a.HCPCS_CD=b.HCPCS_CPT and year(a.CLM_THRU_DT)=b.CY
where CLM_FAC_TYPE_CD+CLM_SRVC_CLSFCTN_TYPE_CD in ('12','13','43','71','73','76','77','85')

/***********************************************************************************************

EDS FINAL

--this is the list of all EDS risk eligible claims. 
***********************************************************************************************/

select * into dbo.EDS_ALL from (
select CLM_CNTL_NUM from dbo.EDS_PHYS union
select CLM_CNTL_NUM from dbo.EDS_IP union
select CLM_CNTL_NUM from dbo.EDS_OP) a;

/***********************************************************************************************
END CODE. A la orden.
***********************************************************************************************/
