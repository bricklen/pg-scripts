Postgres environment
==========================

Disclaimer
----------
These are Bricklen's personal notes, and may or may not be relevant to your environment.
They are subject to change at any time.

Documentation
--------------
* Documented replication topology
* Documented network topology
* Documented interface topology - including users, passwords, connection estimates, load balancers, connection proxies
* Documented procedure, schedule for failover and testing
* Documented procedure, schedule for disaster recovery and testing
* Documented procedure, schedule for maintenance, upgrades
* Documented procedure, schedule for data expiration
* Documented procedure, schedule for backups and testing
* Documented schedule for system upgrades
* Document where to find secrets and passwords (eg. blackbox)
* Document how to encrypt and decrypt backups.
* Create playbooks for anything you can plan for.

Automation
----------
* Automated maintenance
* Automated disaster recovery testing
* Automated backup testing, eg. [Erawan](https://github.com/dgorley/erawan)
* Automated stage environment setup
* Automated data expiration
* Automated failover<sup>1</sup>
* Automated user management
* Configuration change management

Monitoring
----------
* Monitoring of key Postgres performance indicators:
  * query duration,
  * query counts,
  * "tracer" queries executed regularly, used to determine baseline latencies.
  * IO utilization,
  * Number of connections, disconnections
  * Transaction counts, sampled
  * Idle connections
  * commits vs rollbacks
  * checkpoint frequency
  * database size, db growth projections
  * cache hits,
  * hot tables (heavy churn),
  * H.O.T (Heap Only Tuples)
  * locks,
  * cancelled queries,
  * vacuum frequency, duration, and progress
  * large shared buffer "churn" events,
  * size of tables,
  * growth of tables,
  * size of databases,
  * growth of databases,
  * size of indexes,
  * growth of indexes,
  * bloat,
  * tables with high sequential scan counts (indexing targets),
  * network throughput
* Monitoring of key application performance indicators:
  * query plans that scan a high % of partitioned tables
  * duration of stored procedures called regularly
* System monitoring: CPU, memory, IO, swap, DB connections
* Replication monitoring: replication delay by bytes and by seconds, and if the standby is caught up
* Specific to pg_dump backups on the replicas - check the replica via "pg_is_wal_replay_paused()" to see if the replica is still paused after a backup finished (or aborted). if so, execute "pg_wal_replay_resume()".

Configuration
-------------
* Automated pg_hba.conf and user management through configuration management tool
* postgresql.conf managed through configuration management tool
* recovery.conf maintained with configuration management tool
* MTU sizes between applications and db server must match, otherwise you can get mysterious hangs.
  http://www.pateldenish.com/2017/12/tracing-tableau-to-postgres-connectivity-issue-using-wireshark.html

Operations
----------
* n+1 topology for replication/failover
* Disaster Recovery replica set running with delayed WAL application. Eg, 1 hour delay, using [recovery_min_apply_delay](https://www.postgresql.org/docs/current/static/standby-settings.html#RECOVERY-MIN-APPLY-DELAY)
* PITR archive for recovery from operator/developer error
* Backup testing completed weekly
* Failver, Disaster recovery testing completed once per quarter
* Uptime target for all systems defined and agreed to by users

Capacity Planning
-----------------
* Gather metrics from large-scale testing and forecast scale and growth requirements.

Backup and Recovery
-------------------
* This is the bread and butter for a DBA, so every aspect of B&R must be thoroughly tested.
* Define how backups are going to be taken.
* The purpose of each type, where they are going, commands to run them, commands to test them.
* [WAL-E](https://github.com/wal-e/wal-e#google-storage) does work with GCP, [WAL-G](https://github.com/wal-g/wal-g) currently does not work with GCP.
* Investigate physical backups using [pgbackrest](http://pgbackrest.org/)
* Document and test how recoveries are to happen, what the commands are, who should have access, when a recovery should happen.

Availability
------------
* Research and document SLA's, SLO's, RPO's, and RTO's. What are the hard and soft limits?
* Do all components of the database ecosystem require the same level of uptime and availability?

Security
--------
* User/role permissions, general and specific to relations and functions.
* Personally Identifiable Informatin (PII). 
    * Have you identified all PII data? Is there a process to track any new PII-type data?
    * Is all PII secure?
    * Can it be leaked in any way?
    * What happens if an unauthorized person gets access to it?
    * Are passwords stored unencrypted?
    * Does the PII need to be encrypted?
    * Are backups encrypted?
    * Are backups shipped securely to a secure location?
* Is Row Level Security (RLS) necessary?
* Use the monitoring roles, new in PG10
* Database user creds need to be looked up somewhere secure (blackbox, Consul, Vault)

Data Stewardship
----------------
Data stewardship is the process of managing the lifecycle of data from collection to retirement. 
Data stewardship is about defining and maintaining data models, documenting the data, cleansing the data, and defining the rules and policies. 
It enables the implementation of well-defined data governance processes covering several activities including monitoring, reconciliation, refining, deduplication, cleansing and aggregation to help deliver quality data to applications and end users.
In addition to improved data integrity, data stewardship helps ensure that data is being used consistently through the organization, and reduces data ambiguity through metadata and semantics.
More briefly, data stewardship reduces “bad data” in your company, which translates to better decision-making and the elimination of the costs incurred when using incorrect information.

Connections
-----------
* Are TLS/SSL connections to/from Postgres clusters required?
* Does unencrypted data leave the internal network?
* Are the firewalls and listen_addresses settings locked down to IP ranges or DNS names?
* Investigate [client authentication](https://www.postgresql.org/docs/current/static/auth-methods.html) for each environment.

Postgresql Ecosphere Report Card
--------------------------------
This is an document you can refer to and keep up to date every quarter or month, and can be used to generate action items.

 | What | Completion % | Grade | Tools | Details | Action Items |
 | --- | --- | --- | --- | --- | --- |
 | Performance, configuration| - | - | - | Configuration changes, testing of changes for performance improvements. | - |
 | Performance, queries| - | - | pgbader, EXPLAIN | Ongoing, query tuning, schema changes | - |
 | Monitoring, alerting| - | - | Sensu, cron, emails, slack, Splunk | Tracking and notification of relevant metrics. | - | 
 | Metrics, instrumentation| - | - | Prometheus, other | Tracking and notification of relevant health statistics and metrics. | - |
 | Observability | - | - | Honeycomb, other | - | - |
 | Automation| - | - | - | Automate as many steps as possible. Including backups, failovers, recoveries, new server/db creation, new users and roles.. | - |
 | Testing| - | - | What methods are used to test databases and queries? TAP, unit, integration testing? Are dev and staging environments available? Are they regularly cleaned up? Are they easy to spin up? | - | - |
 | Dashboard| - | - | - | - | - |
 | Code releases and upgrades| - | - | - | - | - |
 | Linux/postgres patching| - | - | - | - | - |
 | SLOs/SLIs| - | - | pg_isready | Uptime, Availability, saturation, latency, RPO, RTO, MTTB, MTTR | - |   
 | Replication| - | - | WAL-E, streaming, logical | Can replication be rebuilt with a high degree of success? Can it be done quickly, and with a minimum of interaction? | - |
 | Replication rebuilds| - | - | pg_rewind, custom rebuild scripts | - | - | 
 | Failover| - | - | custom, pg_auto_failover, Patroni | Determine when and how to failover. Should be tooling to allow full functionality. | - | 
 | Discoverability and routing| - | - | Consul, HAProxy, other | Can the databases and clusters and servers be discovered easily, without ambiguity? It must be 100% clear what the primary is at all times. | - |
 | Maintenance| - | - | - | Detecting databases that are in need of maintenance. Ongoing maintenance cycles. | - |
 | Database design| - | - |- | Do we regularly review our design? Do we tackle tech debt? Do we factor in the usage of the schema and data, and the underlying hardware? Are we using the proper datatypes, and using Postgres effectively? | - |
 | Tooling| - | - | - | Are the tools used by all teams effective, easy to find and debug? Do they cover all use cases? Where are the gaps? What is the best language to use (eg. Shell, Python, Go)? | - |
 | Naming conventions and schema clarity| - | - | - | Naming conventions and documentation of object (tables/views/functions) functionality. | - |
 | Documentation and playbooks| - | - | - | Are the proper things documented? Is the documentation clear, and easy to find? Do playbooks exist for common or important issues? Do the docs fall out of date quickly? | - |
 | Data quality| - | - | - | Is data quality checked regularly? Is validation scriptable? Eg. Invalid characters in data, unused columns or tables. | - |
 | Indexing| - | - | - | Do proper indexes exist? Any high write, low read? Unused indexes? Columns indexed multiple times? | - |
 | Knowledge and training| - | - |- | Education level of Postgres features, Do's and Dont's, Best Practices, tailored to devs and DBA's as necessary. | - | 
 | Security and access controls| - | - | - | TLS/SSL connections? Does unencrypted data leave the network? Is data encrypted at rest? Are backups encrypted? Is the encryption key safe? pg_hba.conf, permissions to objects in the databases, proper roles to query data, OS-level permissions and accountability. IPS/IDS, security breach prevention. Encryption (backups, at rest), other | - |
 | Auditing/auditability| - | - |- | Ability to audit who connects to the databases, when, what they do. | - |
 | Support and code reviews| - | - | - | Are the DBA's communicating clearly, regularly, and effectively to developers and business leaders? Are they part of every relevant code review? Is there an established and frictionless feedback loop for bugs and suggestions? | - |
 | Cluster role identification| - | - | - | Must be able to determine with 100% accuracy the role of a Postgres cluster at all times. (master/replica etc) | - |
 | Analytics and reporting| - | - | - | Analysis of our data, Postgresql-specific, as well as client data. Are deeper analytics desirable, if so, is it possible to get that data without undue resource usage? Are tools in place so that analysts and power users can get the data they need? | - |
 | Backups, status/accounting| - | - |- | Ability to determine the status of backups, duration, age, location, size. Deadman switch to alert if backups haven't occurred. | - |
 | Backups, testing| - | - | Erawan, custom | Backups cannot be relied upon unless they are restored and tested. Is there a process in place to test the backups regularly? Is the status tracked? Are long-running backups tracked? What about backups that failed silently? | - |
 | Backup types| - | - | - | Bootstrap, logical, physical | - |
 | Recovery options| - | - | - | What recovery options must exist in the environment to be able to meet RPO and RTO requirements? | - |
 | ETL/ELT, bulk loading| - | - | - | What are the requirements for ETL? Is bulk loading necessary? Are these easy to achieve, without unexpected problems or human error? | - |
 | Change management| - | - | - | Version control, git, puppet/ansible. Is DDL and all db-related code in version control? Does it get deployed to Postgres in a repeatable and safe fashion? | - |
 | Data export| - | - | - | Customer driven, archiving, long-term data storage, etc. Somewhat similar to Archiving. | - |
 | Data stewardship| - | - | - | Do policies exist around data retention, archiving older data, and purging unnecessary data? Have GDPR policies been followed? | - |
 | PITR| - | - | WAL-E, WAL-G, custom | Is Point in Time Recovery required? Can base backups + WALs be kept in offsite storage locations in the event a recovery is needed? Is HA required? | - |
 | Data availability/reporting| - | - | - | Is your data available to be queried by other tools? Is reporting, ad hoc and scheduled, required? | - |
 | Connectivity tracking| - | - | - | Is connectivity to/from/between databases being monitored? Are notifications set up to alert if there is a break in connectivity? Are there statistics being tracked about connectivity? | - |
 | Capacity Planning| - | - | - | Track and extrapolate for servers, databases, tables/indexes, connection counts, users. If we own our own servers, do we need to plan well in advance to purchase hardware? | - |
 | High Availability| - | - | - | Is HA required? Has it been tested thoroughly? | - |
 | Disaster Recovery| - | - | - | What are the requirements for DR? Do you have full support from senior management? Do DR facilities exist? Are DR processes regularly tested? | - |
 | Business Continuity| - | - | - | Is there a business continuity plan? Does it include the proper stakeholders, escalation contacts, and how privileges and permissions should work if key people are not available? | - |
 | RCA and DMAIC process| - | - | - | Is there a process in place to conduct RCA's, and a template to follow? Are action items created and followed up on? | - |
 | Major Incident management| - | - | - | Have major incidents been discussed and planned for? Does everyone know their role? Is there a process in place for clear lines of communication? What are the alternate methods of communication? Is the MIM process regularly tested, particularly when there is stakeholder turnover? Have data breaches and security incidents been covered? | - |
 | Cloud computing| - | - | - | A large topic, and would include private vs public, providers, networking, monitoring, tooling, experience and training, skills leveling-up. | - |
 


Considerations
--------------
1. PostgreSQL High Availability review. Ensure that your database is highly available in order to meet SLA requirements.
1. Backup/Recovery and disaster management review. Plan backups of your data for disaster mitigation and point-in-time recovery. Clearly define what each form of backup is intended to recover from.
1. Security review. Understand the access requirements of the organization and then review security and encryption settings of the system. 
1. Parameter tuning recommendations. Based on organizational goals, tune configuration parameters to maximize throughput and decrease latencies.
1. Vacuum/Analyze strategy review. Vacuum takes up time and power, but we also need to get rid of dead tuples and disk bloat. The key is to strike the right balance.
1. Hardware and OS configuration review. It is not just the database configuration that impacts performance, throughput also depends on hardware configuration and how the operating system features are utilized.
1. Best practices review. Lay out the best practices for each aspect of Postgres administration, backups, failovers, recoveries, and tuning.
1. Connection pooling review. Optimize your connection pooling strategy based on application needs.
1. Review of bulk data load strategy. In case bulk data loads are required by your organization, review their usage, take into account memory requirements of large COPY statements.
1. SLA compliance review. Based on SLAs that you might have with your customers, review the overall integrity of your database to ensure that you can maintain your SLA obligation.
1. Standards compliance review. If your business needs to comply with industry standards, ensure that PostgreSQL features meet this requirement.
1. Are your processes and documentation up to date, and sufficient to successfully get through a catastrophic failure?
As a thought exercise, imagine the network your documentation is in (eg. internal network), are you able to keep your databases available and working correctly for your clients through the period of the outage. 
1. Research any "bad habits" that exist in the current architecture. Do any of the identified issues need to be fixed.
1. Log rotation
1. Are Postgres logs monitored? Are action items created as appropriate?
1. Is the slow query log regularly reviewed, and parsed using a tool like [pgBadger](https://github.com/dalibo/pgbadger)
1. Review the details at https://www.skuggor.se/deployment-checklist.html, there are some good points there.


Credits
-------
Original forked from https://gist.github.com/selenamarie/8724731


<sup>1</sup> About automation of failover. Can be varying levels of automation depending on the environment. Most important bit is once the system or operator has decided failover is necessary, next steps should be automatic to avoid errors.

