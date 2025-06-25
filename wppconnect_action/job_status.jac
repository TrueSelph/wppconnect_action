import from enum { unique }

@unique
enum JobStatus {
    PENDING = 'PENDING',
    PROCESSED = 'PROCESSED',
    FAILED = 'FAILED',
}