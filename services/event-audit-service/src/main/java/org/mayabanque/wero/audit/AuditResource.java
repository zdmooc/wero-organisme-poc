package org.mayabanque.wero.audit;

import jakarta.annotation.security.RolesAllowed;
import jakarta.transaction.Transactional;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import java.time.Instant;
import java.util.List;

@Path("/audit/events")
@Produces(MediaType.APPLICATION_JSON)
public class AuditResource {
    @GET @Path("/{paymentId}") @RolesAllowed("audit-read") @Transactional
    public List<AuditEventView> byPayment(@PathParam("paymentId") String paymentId) {
        List<AuditEventEntity> rows = AuditEventEntity.list("paymentId = ?1 order by id", paymentId);
        return rows.stream().map(r -> new AuditEventView(r.id, r.eventId, r.paymentId, r.eventType,
                r.paymentStatus, r.correlationId, r.traceId, r.kafkaPartition, r.kafkaOffset, r.receivedAt)).toList();
    }

    public record AuditEventView(Long id, String eventId, String paymentId, String eventType, String status,
                                 String correlationId, String traceId, int kafkaPartition, long kafkaOffset,
                                 Instant receivedAt) {}
}
