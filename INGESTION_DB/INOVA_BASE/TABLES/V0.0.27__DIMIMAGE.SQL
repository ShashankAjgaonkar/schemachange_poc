create TABLE if not exists {{ environment }}_INGESTION_DB.INOVA_BASE.DIMAGE (
	AGESK NUMBER(38,0) NOT NULL,
	AGERANGE VARCHAR(50),
	BASECREATEDDATE TIMESTAMP_NTZ(9),
	BASEUPDATEDDATE TIMESTAMP_NTZ(9),
	BASEDELETEDFLAG NUMBER(38,0),
	TEST1 VARCHAR(16777216),
	TEST2 VARCHAR(16777216),
	TEST3 NUMBER(38,0)
);
