# FFDC Prompt Examples — Ollama s390x

**Purpose:** Copy-paste prompt catalog for First Failure Data Capture (FFDC) and E2E
integration teams using Ollama on IBM Z (s390x).  
**Release:** `v0.2.0`  
**Base URL:** `http://localhost:11434`  
**Recommended model:** `granite3.3:2b` (IBM model, best structured-output compliance on s390x)  
**Related docs:** [`docs/e2e_ffdc_integration.md`](../docs/e2e_ffdc_integration.md) · [`docs/api_contract.md`](../docs/api_contract.md)

---

## Table of Contents

1. [Abend & Exception Parsing](#1-abend--exception-parsing)
   - 1.1 [S0C4 — Protection Exception](#11-s0c4--protection-exception)
   - 1.2 [S0C7 — Data Exception](#12-s0c7--data-exception)
   - 1.3 [S0CB — Divide Exception](#13-s0cb--divide-exception)
   - 1.4 [S322 — Time Limit Exceeded](#14-s322--time-limit-exceeded)
   - 1.5 [S806 — Module Not Found](#15-s806--module-not-found)
2. [Log Anomaly Detection](#2-log-anomaly-detection)
   - 2.1 [Single log line classification](#21-single-log-line-classification)
   - 2.2 [Multi-line log anomaly scan](#22-multi-line-log-anomaly-scan)
3. [Incident Summary Generation](#3-incident-summary-generation)
   - 3.1 [Short incident summary](#31-short-incident-summary)
   - 3.2 [Formal incident report](#32-formal-incident-report)
4. [Root Cause Analysis](#4-root-cause-analysis)
   - 4.1 [Performance bottleneck RCA](#41-performance-bottleneck-rca)
   - 4.2 [Storage / memory RCA](#42-storage--memory-rca)
   - 4.3 [I/O subsystem RCA](#43-io-subsystem-rca)
5. [Structured Output Templates](#5-structured-output-templates)
   - 5.1 [Abend classification schema](#51-abend-classification-schema)
   - 5.2 [Incident record schema](#52-incident-record-schema)
   - 5.3 [Performance alert schema](#53-performance-alert-schema)
6. [E2E Baseline Prompts](#6-e2e-baseline-prompts)
   - 6.1 [Deterministic smoke prompt](#61-deterministic-smoke-prompt)
   - 6.2 [Context window utilization test](#62-context-window-utilization-test)
7. [Long Log Analysis](#7-long-log-analysis)
   - 7.1 [Job log summarization](#71-job-log-summarization)
   - 7.2 [SMF record anomaly detection](#72-smf-record-anomaly-detection)

---

## 1. Abend & Exception Parsing

### 1.1 S0C4 — Protection Exception

**Use case:** Parse a standard IEA995I symptom dump for a Protection Exception (most common
z/OS abend in FFDC pipelines).

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Parse this z/OS abend log entry into structured fields:\n\nIEA995I SYMPTOM DUMP OUTPUT\n  TIME=14.23.41 SEQ=03271 CPU=0000 ASID=00AF\n  PSW AT TIME OF ERROR  078D1000 80000000  00000000 00123456\n  REASON CODE = 0C4",
    "format": {
      "type": "object",
      "properties": {
        "message_id":         { "type": "string" },
        "time":               { "type": "string" },
        "asid":               { "type": "string" },
        "reason_code":        { "type": "string" },
        "error_type":         { "type": "string" },
        "severity":           { "type": "string", "enum": ["LOW","MEDIUM","HIGH","CRITICAL"] },
        "recommended_action": { "type": "string" }
      },
      "required": ["message_id","time","asid","reason_code","error_type","severity","recommended_action"]
    },
    "stream": false,
    "options": { "temperature": 0.0 }
  }' | jq -r .response | jq .
```

**Expected output:**
```json
{
  "message_id": "IEA995I",
  "time": "14.23.41",
  "asid": "00AF",
  "reason_code": "0C4",
  "error_type": "Protection Exception (ABEND S0C4)",
  "severity": "HIGH",
  "recommended_action": "Investigate memory access at address 00123456 in job associated with ASID 00AF. Capture SVC dump and review IPCS ANALYZE output."
}
```

---

### 1.2 S0C7 — Data Exception

**Use case:** Parse a data exception abend — commonly caused by uninitialized packed decimal fields.

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Parse this z/OS abend log entry into structured fields:\n\nIEA995I SYMPTOM DUMP OUTPUT\n  TIME=09.45.12 SEQ=01842 CPU=0001 ASID=0033\n  PSW AT TIME OF ERROR  070C1000 80000000  00000000 00456789\n  REASON CODE = 0C7",
    "format": {
      "type": "object",
      "properties": {
        "message_id":         { "type": "string" },
        "time":               { "type": "string" },
        "asid":               { "type": "string" },
        "reason_code":        { "type": "string" },
        "error_type":         { "type": "string" },
        "severity":           { "type": "string", "enum": ["LOW","MEDIUM","HIGH","CRITICAL"] },
        "recommended_action": { "type": "string" }
      },
      "required": ["message_id","time","asid","reason_code","error_type","severity","recommended_action"]
    },
    "stream": false,
    "options": { "temperature": 0.0 }
  }' | jq -r .response | jq .
```

**Expected output:**
```json
{
  "message_id": "IEA995I",
  "time": "09.45.12",
  "asid": "0033",
  "reason_code": "0C7",
  "error_type": "Data Exception (ABEND S0C7) — invalid packed decimal operand",
  "severity": "HIGH",
  "recommended_action": "Review COBOL or PL/I program running in ASID 0033 for uninitialized or corrupted packed decimal fields. Check MOVE/INITIALIZE statements for numeric fields."
}
```

---

### 1.3 S0CB — Divide Exception

**Use case:** Parse a divide-by-zero or divide overflow abend.

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Parse this z/OS abend log entry into structured fields:\n\nIEA995I SYMPTOM DUMP OUTPUT\n  TIME=16.02.55 SEQ=00912 CPU=0000 ASID=00B2\n  PSW AT TIME OF ERROR  078D1000 80000000  00000000 00789ABC\n  REASON CODE = 0CB",
    "format": {
      "type": "object",
      "properties": {
        "message_id":         { "type": "string" },
        "time":               { "type": "string" },
        "asid":               { "type": "string" },
        "reason_code":        { "type": "string" },
        "error_type":         { "type": "string" },
        "severity":           { "type": "string", "enum": ["LOW","MEDIUM","HIGH","CRITICAL"] },
        "recommended_action": { "type": "string" }
      },
      "required": ["message_id","time","asid","reason_code","error_type","severity","recommended_action"]
    },
    "stream": false,
    "options": { "temperature": 0.0 }
  }' | jq -r .response | jq .
```

**Expected output:**
```json
{
  "message_id": "IEA995I",
  "time": "16.02.55",
  "asid": "00B2",
  "reason_code": "0CB",
  "error_type": "Divide Exception (ABEND S0CB) — division by zero or quotient overflow",
  "severity": "HIGH",
  "recommended_action": "Locate the division instruction at address 00789ABC in ASID 00B2. Add a pre-division zero check in the program or validate input data ranges."
}
```

---

### 1.4 S322 — Time Limit Exceeded

**Use case:** Classify a job cancellation due to CPU time limit (TIME= exceeded).

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Classify this z/OS system message and determine if it indicates a problem requiring FFDC action:\n\nIEF272I jobname ENDED - TIME LIMIT EXCEEDED\n  JOB PAYR0042 ENDED.  SYSTEM=S322  JCPU=00:15:00.00 ELAPSED=00:16:23",
    "format": {
      "type": "object",
      "properties": {
        "job_name":           { "type": "string" },
        "abend_code":         { "type": "string" },
        "error_type":         { "type": "string" },
        "cpu_time_used":      { "type": "string" },
        "requires_ffdc":      { "type": "boolean" },
        "severity":           { "type": "string", "enum": ["LOW","MEDIUM","HIGH","CRITICAL"] },
        "recommended_action": { "type": "string" }
      },
      "required": ["job_name","abend_code","error_type","cpu_time_used","requires_ffdc","severity","recommended_action"]
    },
    "stream": false,
    "options": { "temperature": 0.0 }
  }' | jq -r .response | jq .
```

**Expected output:**
```json
{
  "job_name": "PAYR0042",
  "abend_code": "S322",
  "error_type": "Time Limit Exceeded — job consumed allocated CPU time",
  "cpu_time_used": "00:15:00",
  "requires_ffdc": true,
  "severity": "MEDIUM",
  "recommended_action": "Review job PAYR0042 for infinite loops or excessive processing. Consider increasing TIME= parameter if workload is legitimate. Review for runaway DB2 queries or VSAM I/O wait loops."
}
```

---

### 1.5 S806 — Module Not Found

**Use case:** Detect a load failure due to missing load module.

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Classify this z/OS system message:\n\nIEA101A ABEND S806  U0000  MODULE=PAYROLL2  JOBNAME=PAYR0099\nIEF272I PAYR0099 ENDED - ABEND=S806",
    "format": {
      "type": "object",
      "properties": {
        "job_name":           { "type": "string" },
        "abend_code":         { "type": "string" },
        "missing_module":     { "type": "string" },
        "error_type":         { "type": "string" },
        "severity":           { "type": "string", "enum": ["LOW","MEDIUM","HIGH","CRITICAL"] },
        "recommended_action": { "type": "string" }
      },
      "required": ["job_name","abend_code","missing_module","error_type","severity","recommended_action"]
    },
    "stream": false,
    "options": { "temperature": 0.0 }
  }' | jq -r .response | jq .
```

**Expected output:**
```json
{
  "job_name": "PAYR0099",
  "abend_code": "S806",
  "missing_module": "PAYROLL2",
  "error_type": "Load Module Not Found — STEPLIB/JOBLIB does not contain required load module",
  "severity": "HIGH",
  "recommended_action": "Verify PAYROLL2 exists in the load library concatenation for PAYR0099. Check STEPLIB DD and system LINKLIST. May indicate a failed deployment or incorrect JCL."
}
```

---

## 2. Log Anomaly Detection

### 2.1 Single log line classification

**Use case:** Classify a single system message as normal, warning, or error for real-time
log stream processing.

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Classify this IBM Z system message as NORMAL, WARNING, or ERROR. Explain the classification in one sentence.\n\nIEF404I PAYROLL - UNABLE TO OBTAIN REQUIRED RESOURCES",
    "format": {
      "type": "object",
      "properties": {
        "classification": { "type": "string", "enum": ["NORMAL","WARNING","ERROR"] },
        "explanation":    { "type": "string" }
      },
      "required": ["classification","explanation"]
    },
    "stream": false,
    "options": { "temperature": 0.0 }
  }' | jq -r .response | jq .
```

**Expected output:**
```json
{
  "classification": "ERROR",
  "explanation": "IEF404I indicates a job failed to obtain required system resources, preventing successful execution — this is an error condition requiring investigation."
}
```

---

### 2.2 Multi-line log anomaly scan

**Use case:** Scan a batch of log messages and return only those requiring attention.

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Review these z/OS system log messages. List only the messages that indicate errors or warnings requiring operator attention. For each, provide the message ID and a brief explanation.\n\nIEF237I DMY   ALLOC. FOR PAYR0042\nIEF142I PAYR0042 - STEP1 - STEP WAS EXECUTED\nIEF404I PAYROLL - UNABLE TO OBTAIN REQUIRED RESOURCES\nIEF285I   VOL SER NOS= SYSRES.\nIEF272I PAYR0042 ENDED. ABEND=S806\nIEF237I DMY   ALLOC. FOR REPT0001\nIEF142I REPT0001 - STEP1 - STEP WAS EXECUTED\nIEF285I   VOL SER NOS= PROD01.\nIEF373I STEP /STEP1  / START 2026181.1423\nIEF374I STEP /STEP1  / STOP  2026181.1424 CPU  0MIN 02.11SEC",
    "stream": false,
    "options": { "temperature": 0.1, "seed": 42, "num_predict": 300 }
  }' | jq .response
```

**Expected response (representative):**
```
Messages requiring attention:

1. IEF404I — PAYROLL job was unable to obtain required system resources. This
   prevents the job from executing and requires investigation of resource
   availability (e.g., DD allocation failures, ENQ contention).

2. IEF272I (ABEND=S806) — PAYR0042 ended with an S806 abend, indicating a load
   module was not found in the STEPLIB/JOBLIB concatenation. Verify the load
   library contents and JCL for PAYR0042.
```

---

## 3. Incident Summary Generation

### 3.1 Short incident summary

**Use case:** Generate a 3-sentence triage summary for a shift handoff or ticketing system.

```sh
curl -s http://localhost:11434/api/chat \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "messages": [
      {
        "role": "system",
        "content": "You are an IBM Z systems expert. Generate concise FFDC incident summaries. Use exactly 3 sentences: (1) what happened, (2) impact, (3) recommended next step."
      },
      {
        "role": "user",
        "content": "Summarize: 47 abend S0C4 events between 14:20 and 14:35. Affected ASID 00AF. Memory address 00123456 not accessible. LPAR utilization 98% during event window."
      }
    ],
    "stream": false,
    "options": { "temperature": 0.1, "seed": 42 }
  }' | jq .message.content
```

**Expected response (representative):**
```
Between 14:20 and 14:35, ASID 00AF experienced 47 ABEND S0C4 (Protection Exception)
events caused by repeated attempts to access memory address 00123456. The failure
cascade coincided with LPAR utilization at 98%, suggesting resource contention
amplified the error frequency and extended impact. Immediate next step: capture an
SVC dump for ASID 00AF and review recent program changes for invalid memory references.
```

---

### 3.2 Formal incident report

**Use case:** Generate a structured incident report suitable for ticketing or FFDC database insertion.

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Generate a formal z/OS incident report from this data:\n\nEvent: Multiple S0C4 abends\nTime window: 14:20-14:35 on 2026-07-10\nAffected ASID: 00AF\nAbend count: 47\nFailing address: 00123456\nLPAR utilization: 98%\nResolution status: Under investigation",
    "format": {
      "type": "object",
      "properties": {
        "incident_id":      { "type": "string" },
        "severity":         { "type": "string", "enum": ["SEV1","SEV2","SEV3","SEV4"] },
        "title":            { "type": "string" },
        "affected_system":  { "type": "string" },
        "time_of_first_occurrence": { "type": "string" },
        "event_count":      { "type": "integer" },
        "root_cause_hypothesis": { "type": "string" },
        "immediate_actions": {
          "type": "array",
          "items": { "type": "string" }
        },
        "status":           { "type": "string", "enum": ["OPEN","IN_PROGRESS","RESOLVED","CLOSED"] }
      },
      "required": ["incident_id","severity","title","affected_system","time_of_first_occurrence","event_count","root_cause_hypothesis","immediate_actions","status"]
    },
    "stream": false,
    "options": { "temperature": 0.0 }
  }' | jq -r .response | jq .
```

**Expected output:**
```json
{
  "incident_id": "INC-20260710-00AF",
  "severity": "SEV2",
  "title": "Repeated ABEND S0C4 — Protection Exception in ASID 00AF",
  "affected_system": "ASID 00AF (z/OS LPAR)",
  "time_of_first_occurrence": "2026-07-10 14:20",
  "event_count": 47,
  "root_cause_hypothesis": "Invalid memory access at address 00123456; possibly a dangling pointer or buffer overrun in a program running in ASID 00AF, exacerbated by 98% LPAR CPU utilization causing timing-sensitive failures.",
  "immediate_actions": [
    "Capture SVC dump for ASID 00AF",
    "Isolate and hold the failing job to prevent recurrence",
    "Review IPCS ANALYZE output for storage overlays",
    "Check for recent program deployments in ASID 00AF"
  ],
  "status": "IN_PROGRESS"
}
```

---

## 4. Root Cause Analysis

### 4.1 Performance bottleneck RCA

**Use case:** Identify primary and contributing bottlenecks from a set of performance metrics.

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Given these IBM Z performance metrics, identify the root cause of the SLA breach and provide the top 3 remediation steps:\n\nCPU utilization: 94%\nMemory utilization: 87%\nI/O wait: 42%\nPage faults/sec: 1200\nTransaction response time: 8.3s (SLA: 2.0s)\nActive address spaces: 312\nPaging rate: 980 pages/sec",
    "stream": false,
    "options": { "temperature": 0.0, "seed": 42, "num_predict": 400 }
  }' | jq .response
```

**Expected response (representative):**
```
Root cause: Memory thrashing. With 1200 page faults/sec and 980 pages/sec paging
rate against 87% memory utilization and 312 active address spaces, the system is
spending a disproportionate fraction of CPU cycles handling page-in I/O from DASD.
This explains both the 42% I/O wait and the 94% CPU reading (elevated by paging
overhead). Transaction latency (8.3s vs 2.0s SLA) is a direct consequence.

Remediation steps:
1. Increase real storage for the LPAR or reduce the number of concurrent address
   spaces via WLM policy — target ≤ 240 active address spaces.
2. Review DFSMS HSM recall and page dataset placement; move page datasets to
   faster DASD tiers (EAV or flash) to reduce page-in latency.
3. Implement WLM service class CPU and memory caps to prevent workload runaway
   from monopolizing frames and starving higher-priority service classes.
```

---

### 4.2 Storage / memory RCA

**Use case:** Diagnose a memory-related failure pattern from CSA/ECSA exhaustion messages.

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Analyze these z/OS storage-related messages and identify the root cause and remediation:\n\nIRA200E CSA STORAGE REQUEST FAILED - TOTAL=32M LIMIT=32M\nIRA200E ECSA STORAGE REQUEST FAILED - TOTAL=64M LIMIT=64M\nIEA995I ABEND 878 - VIRTUAL STORAGE EXHAUSTED ASID=00C1\nIRA200E CSA STORAGE REQUEST FAILED (repeat x 23 in 5 minutes)",
    "stream": false,
    "options": { "temperature": 0.0, "seed": 42, "num_predict": 400 }
  }' | jq .response
```

**Expected response (representative):**
```
Root cause: CSA and ECSA storage exhaustion. The IRA200E messages confirm that both
Common Service Area regions have reached their configured limits (32M and 64M
respectively), causing subsequent storage requests to fail. The S878 abend in ASID
00C1 is a direct consequence — that address space's GETMAIN request for virtual
storage failed because the above-the-bar CSA/ECSA pool is depleted. The 23 repeat
IRA200E messages in 5 minutes indicate a persistent and worsening condition.

Remediation:
1. Immediately identify which subsystem or address space is consuming CSA/ECSA —
   use D VIRTSTOR,CSA and IPCS CBFORMAT to find the largest consumers.
2. Increase CSA and ECSA limits in IEASYSxx (CSA=48M, ECSA=96M as a temporary
   measure) and IPL with the new parameters.
3. Investigate the root consumer for a storage leak — common culprits include
   third-party monitoring agents, DB2 buffer pools, or CICS storage violations.
```

---

### 4.3 I/O subsystem RCA

**Use case:** Diagnose DASD / channel I/O errors from hardware and software messages.

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Analyze these z/OS I/O error messages and identify the root cause:\n\nIOS001A UNIT 0A40 INTERVENTION REQUIRED\nIOS020I CHANNEL PATH 42 REPORTED ERROR\nIOS220E DEVICE 0A40 SENSE DATA: XX44 0000 0000 0000\nIECIOERR 001 I 01  40 0A40\nIEA494E SEVERE I/O ERROR ON DEVICE 0A40 - JOB PAYMENT1 WAITING",
    "stream": false,
    "options": { "temperature": 0.0, "seed": 42, "num_predict": 350 }
  }' | jq .response
```

**Expected response (representative):**
```
Root cause: Hardware I/O error on DASD device 0A40, likely a physical drive fault or
channel path degradation. The IOS001A message indicates operator intervention is
required (device not ready or physically offline). The IOS020I channel path error on
path 42 confirms the failure is at the hardware interface level, not a software
configuration issue. Sense data 0044 typically indicates a media or equipment check
on the disk subsystem.

Remediation:
1. Alert the storage team to inspect device 0A40 and channel path 42 for physical
   faults — check the DS8000/XIV/FlashSystem error logs.
2. If the device is part of a RAID group, verify whether parity reconstruction is
   active and assess the risk to data integrity.
3. Redirect job PAYMENT1 and any other jobs waiting on 0A40 to an alternate volume;
   use VARY 0A40,OFFLINE after ensuring no active I/O.
```

---

## 5. Structured Output Templates

Ready-to-use JSON schemas for common FFDC pipeline use cases.

### 5.1 Abend classification schema

```json
{
  "type": "object",
  "properties": {
    "message_id":         { "type": "string" },
    "time":               { "type": "string" },
    "asid":               { "type": "string" },
    "job_name":           { "type": "string" },
    "reason_code":        { "type": "string" },
    "error_type":         { "type": "string" },
    "severity":           { "type": "string", "enum": ["LOW","MEDIUM","HIGH","CRITICAL"] },
    "requires_dump":      { "type": "boolean" },
    "recommended_action": { "type": "string" }
  },
  "required": ["message_id","time","asid","reason_code","error_type","severity","requires_dump","recommended_action"]
}
```

### 5.2 Incident record schema

```json
{
  "type": "object",
  "properties": {
    "incident_id":               { "type": "string" },
    "severity":                  { "type": "string", "enum": ["SEV1","SEV2","SEV3","SEV4"] },
    "title":                     { "type": "string" },
    "affected_system":           { "type": "string" },
    "time_of_first_occurrence":  { "type": "string" },
    "event_count":               { "type": "integer" },
    "root_cause_hypothesis":     { "type": "string" },
    "immediate_actions":         { "type": "array", "items": { "type": "string" } },
    "status":                    { "type": "string", "enum": ["OPEN","IN_PROGRESS","RESOLVED","CLOSED"] }
  },
  "required": ["incident_id","severity","title","affected_system","time_of_first_occurrence","event_count","root_cause_hypothesis","immediate_actions","status"]
}
```

### 5.3 Performance alert schema

```json
{
  "type": "object",
  "properties": {
    "alert_id":           { "type": "string" },
    "lpar":               { "type": "string" },
    "timestamp":          { "type": "string" },
    "primary_bottleneck": { "type": "string", "enum": ["CPU","MEMORY","IO","NETWORK","STORAGE"] },
    "sla_breach":         { "type": "boolean" },
    "metrics_summary":    { "type": "string" },
    "severity":           { "type": "string", "enum": ["LOW","MEDIUM","HIGH","CRITICAL"] },
    "top_remediation_steps": { "type": "array", "items": { "type": "string" }, "maxItems": 3 }
  },
  "required": ["alert_id","lpar","timestamp","primary_bottleneck","sla_breach","metrics_summary","severity","top_remediation_steps"]
}
```

---

## 6. E2E Baseline Prompts

### 6.1 Deterministic smoke prompt

Use this prompt to verify the model produces stable, reproducible output in CI.
`temperature: 0.0` + `seed: 42` ensures identical output on identical hardware/model/quantization.

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.2:1b",
    "prompt": "Reply with exactly: OK",
    "stream": false,
    "options": {
      "temperature": 0.0,
      "seed": 42,
      "num_predict": 5
    }
  }' | jq .response
```

**Expected:** A response containing the string `"OK"` with `done == true`.

For a faster CI gate (health + inference in 1 command):

```sh
DONE=$(curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{"model":"smollm:135m","prompt":"ping","stream":false,"options":{"temperature":0,"seed":1,"num_predict":3}}' \
  | jq -r '.done')
[[ "$DONE" == "true" ]] && echo "PASS" || echo "FAIL"
```

---

### 6.2 Context window utilization test

Verify the model can handle a full context window without truncation. This is important
for FFDC pipelines that send large log excerpts.

```sh
# Generate a prompt that fills ~1000 tokens, assert prompt_eval_count matches
PROMPT=$(python3 -c "print('z/OS log entry: ' + 'IEF142I STEP EXECUTED. ' * 50)")

curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"granite3.3:2b\",
    \"prompt\": \"$PROMPT Summarize in one sentence.\",
    \"stream\": false,
    \"options\": {
      \"temperature\": 0.0,
      \"num_ctx\": 2048,
      \"num_predict\": 50
    }
  }" | jq '{done: .done, prompt_tokens: .prompt_eval_count, response_tokens: .eval_count}'
```

**Expected response shape:**
```json
{
  "done": true,
  "prompt_tokens": 1024,
  "response_tokens": 22
}
```

If `prompt_tokens` is substantially lower than the actual prompt length, the context was truncated — increase `num_ctx`.

---

## 7. Long Log Analysis

### 7.1 Job log summarization

**Use case:** Summarize a complete z/OS job log (up to ~320 lines with `num_ctx=8192`).

```sh
# Read log from file and send to API
LOG_CONTENT=$(cat /path/to/job.log)

curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg log "$LOG_CONTENT" '{
    model: "granite3.3:2b",
    prompt: ("Summarize the following z/OS job log. List: (1) job outcome, (2) any errors or warnings, (3) recommended actions if any.\n\n" + $log),
    stream: false,
    options: {
      temperature: 0.1,
      seed: 42,
      num_ctx: 8192,
      num_predict: 512
    }
  }')" | jq .response
```

> Use `jq -n --arg` to safely escape multi-line log content into JSON.

---

### 7.2 SMF record anomaly detection

**Use case:** Analyze a batch of SMF type 30 record summaries for anomalous patterns.

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Analyze these SMF type 30 job statistics and flag any jobs with anomalous CPU or I/O usage. Identify outliers and possible causes.\n\nJob       CPU(sec)  Elapsed(sec)  EXCP      SIO\nPAYR0001  12.3      45.2          1200      890\nPAYR0002  11.8      44.1          1180      870\nPAYR0003  14.1      47.3          1350      920\nPAYR0004  892.4     901.2         98420     87320\nPAYR0005  13.2      46.8          1210      895\nPAYR0006  12.9      45.9          1190      880",
    "stream": false,
    "options": { "temperature": 0.1, "seed": 42, "num_predict": 350 }
  }' | jq .response
```

**Expected response (representative):**
```
Anomaly detected: PAYR0004

PAYR0004 is a severe outlier across all metrics:
- CPU: 892.4s vs peer average of ~12.9s (69× higher)
- Elapsed: 901.2s vs peer average of ~45.9s (20× higher)  
- EXCP: 98,420 vs peer average of ~1,226 (80× higher)
- SIO: 87,320 vs peer average of ~891 (98× higher)

Possible causes:
1. Infinite loop or runaway processing — the CPU time is wildly disproportionate
   to the normal batch job pattern.
2. Missing end-of-file condition on a VSAM or sequential dataset causing the job
   to repeatedly read the same records.
3. DB2 or VSAM lock wait causing high elapsed time with corresponding I/O retries.

Recommended action: Review PAYR0004 job history, examine the program for loop
termination conditions, and compare job output with PAYR0001-0003 to identify
the divergent processing path.
```

---

## Reference

### Model quick reference

| Model | Best for | `num_predict` cap | Avg tok/s |
|-------|----------|-------------------|-----------|
| `granite3.3:2b` | Structured output, FFDC parsing | 512 | 12.25 |
| `llama3.2:1b` | E2E baseline, deterministic tests | 100 | 17.6 |
| `smollm:135m` | CI smoke tests, warm-up requests | 20 | 104.6 |

### Key extraction tips

| Response field | Usage |
|----------------|-------|
| `.response` | Model output for `/api/generate` |
| `.message.content` | Model output for `/api/chat` |
| `.done` | Must be `true` before reading output |
| `.eval_count` | Number of generated tokens |
| `.prompt_eval_count` | Number of input tokens processed |
| `.total_duration` | Wall time in nanoseconds (÷ 1e9 = seconds) |

### Related documentation

- [`docs/e2e_ffdc_integration.md`](../docs/e2e_ffdc_integration.md) — full integration guide with failure handling
- [`docs/api_contract.md`](../docs/api_contract.md) — complete API reference
- [`docs/handoff.md`](../docs/handoff.md) — team handoff package
- [`docs/model_compatibility_matrix.md`](../docs/model_compatibility_matrix.md) — tested models and benchmarks
