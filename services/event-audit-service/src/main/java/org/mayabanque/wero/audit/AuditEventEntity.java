package org.mayabanque.wero.audit;

import io.quarkus.hibernate.orm.panache.PanacheEntityBase;
import jakarta.persistence.*;
import java.time.Instant;

@Entity
@Table(name = "payment_audit_events")
public class AuditEventEntity extends PanacheEntityBase {
    @Id @GeneratedValue(strategy = GenerationType.IDENTITY) public Long id;
    @Column(name = "event_id", nullable = false, unique = true, length = 64) public String eventId;
    @Column(name = "payment_id", nullable = false, length = 128) public String paymentId;
    @Column(name = "event_type", nullable = false, length = 64) public String eventType;
    @Column(name = "payment_status", length = 32) public String paymentStatus;
    @Column(name = "correlation_id", length = 128) public String correlationId;
    @Column(name = "trace_id", length = 32) public String traceId;
    @Column(name = "payload", nullable = false, columnDefinition = "text") public String payload;
    @Column(name = "kafka_partition", nullable = false) public int kafkaPartition;
    @Column(name = "kafka_offset", nullable = false) public long kafkaOffset;
    @Column(name = "received_at", nullable = false) public Instant receivedAt;
}
