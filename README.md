# CMS_HCC_Models_SQL
Translating CMS HCC Models from SAS to SQL

This project is intended to provide a SQL Server version of the CMS HCC SAS program to allow smaller Medicare Advantage health plans and provider groups to validate their risk scores. It may not be appropriate for other purposes. My priorities in creating this were as follows:

Flexible. I stayed away from adding in stored procedures to allow users of this code the flexibility to change things to fit their organization/purposes.

Accessible to less advanced SQL users. I am not the most advanced SQL Server coder and this code is not intended to be super-efficient. I attempted to strike a balance between easy-to-understand and effective. 

Operations focused. This code is not intended to be used as a risk score/revenue projection tool for MA bids. My intention is, instead, to provide more transparency into risk scores so organizations can address any issues and spend less time worrying about them.

Finally, if you find any issues or have a unique way to look at things in your organization please feel free to provide feedback and/or add in additional code.
