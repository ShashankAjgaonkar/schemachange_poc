CREATE OR REPLACE FILE FORMAT {{ environment }}_INGESTION_DB.INOVA_BASE.TSV_FF
	TYPE = csv
	FIELD_DELIMITER = '\t'
	ESCAPE_UNENCLOSED_FIELD = 'NONE'
	FIELD_OPTIONALLY_ENCLOSED_BY = '\"'
	NULL_IF = ('NULL', 'null')
	SKIP_BLANK_LINES = TRUE
;