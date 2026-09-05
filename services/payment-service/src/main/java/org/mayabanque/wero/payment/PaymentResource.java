package org.mayabanque.wero.payment;

import jakarta.inject.Inject;
import jakarta.transaction.Transactional;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import java.time.Instant;
import java.util.List;
import java.util.Objects;
import org.eclipse.microprofile.rest.client.inject.RestClient;

@Path("/payments")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
public class PaymentResource {

    @Inject
    @RestClient
    ConsumerPspClient consumerPsp;

    @Inject
    @RestClient
    SctInstStatusClient sctInstStatus;

    @POST
    @Path("/single-immediate")
    @Transactional
    public Response create(@HeaderParam("Idempotency-Key") String idempotencyKey, PaymentRequest request) {
        if (request == null || blank(request.paymentId()) || request.amountCents() <= 0 || blank(request.currency())) {
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(new ErrorResponse("INVALID_REQUEST", "paymentId, positive amountCents and currency are required"))
                    .build();
        }
        if (blank(idempotencyKey)) {
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(new ErrorResponse("IDEMPOTENCY_KEY_REQUIRED", "Idempotency-Key header is required"))
                    .build();
        }

        PaymentEntity existingByKey = PaymentEntity.find("idempotencyKey", idempotencyKey).firstResult();
        if (existingByKey != null) {
            if (!samePayload(existingByKey, request)) {
                return Response.status(Response.Status.CONFLICT)
                        .entity(new ErrorResponse("IDEMPOTENCY_CONFLICT", "The same Idempotency-Key was already used with a different payload"))
                        .build();
            }
            return Response.ok(toResponse(existingByKey))
                    .header("X-Idempotent-Replay", "true")
                    .build();
        }

        PaymentEntity existingById = PaymentEntity.findById(request.paymentId());
        if (existingById != null) {
            return Response.status(Response.Status.CONFLICT)
                    .entity(new ErrorResponse("PAYMENT_ID_CONFLICT", "paymentId already exists with another idempotency key"))
                    .build();
        }

        Instant now = Instant.now();
        PaymentEntity payment = new PaymentEntity();
        payment.paymentId = request.paymentId();
        payment.idempotencyKey = idempotencyKey;
        payment.amountCents = request.amountCents();
        payment.currency = request.currency().toUpperCase();
        payment.debtorAlias = request.debtorAlias();
        payment.creditorAlias = request.creditorAlias();
        payment.simulateMode = request.simulateMode();
        payment.status = PaymentStatus.CREATED;
        payment.createdAt = now;
        payment.updatedAt = now;
        payment.persistAndFlush();

        try {
            payment.status = PaymentStatus.PROCESSING;
            payment.updatedAt = Instant.now();

            PaymentResponse downstream = consumerPsp.pay(request);
            payment.settlementId = downstream.settlementId();
            payment.lastError = null;
            payment.status = switch (downstream.status()) {
                case "SETTLED" -> PaymentStatus.SETTLED;
                case "FAILED" -> PaymentStatus.FAILED;
                default -> PaymentStatus.PENDING;
            };
            payment.updatedAt = Instant.now();

            if (payment.status == PaymentStatus.SETTLED) {
                recordSettlementLedger(payment);
            }
        } catch (Exception e) {
            // Important payment rule: a timeout after submission is UNKNOWN, not FAILED.
            // We must query status/reconcile before considering any replay.
            payment.status = PaymentStatus.UNKNOWN;
            payment.lastError = truncate(e.getClass().getSimpleName() + ": " + String.valueOf(e.getMessage()), 500);
            payment.updatedAt = Instant.now();
        }

        int httpStatus = payment.status == PaymentStatus.UNKNOWN || payment.status == PaymentStatus.PENDING ? 202 : 200;
        return Response.status(httpStatus).entity(toResponse(payment)).build();
    }

    @GET
    @Path("/{paymentId}")
    @Transactional
    public Response get(@PathParam("paymentId") String paymentId) {
        PaymentEntity payment = PaymentEntity.findById(paymentId);
        if (payment == null) {
            return Response.status(Response.Status.NOT_FOUND)
                    .entity(new ErrorResponse("PAYMENT_NOT_FOUND", paymentId))
                    .build();
        }
        return Response.ok(toDetails(payment)).build();
    }

    @GET
    @Path("/{paymentId}/ledger")
    @Transactional
    public Response ledger(@PathParam("paymentId") String paymentId) {
        PaymentEntity payment = PaymentEntity.findById(paymentId);
        if (payment == null) {
            return Response.status(Response.Status.NOT_FOUND)
                    .entity(new ErrorResponse("PAYMENT_NOT_FOUND", paymentId))
                    .build();
        }
        List<LedgerEntryEntity> entries = LedgerEntryEntity.list("paymentId", paymentId);
        List<LedgerEntryView> result = entries.stream()
                .map(e -> new LedgerEntryView(e.id, e.paymentId, e.entryType, e.amountCents, e.currency, e.settlementId, e.createdAt))
                .toList();
        return Response.ok(result).build();
    }

    @POST
    @Path("/{paymentId}/reconcile")
    @Transactional
    public Response reconcile(@PathParam("paymentId") String paymentId) {
        PaymentEntity payment = PaymentEntity.findById(paymentId);
        if (payment == null) {
            return Response.status(Response.Status.NOT_FOUND)
                    .entity(new ErrorResponse("PAYMENT_NOT_FOUND", paymentId))
                    .build();
        }

        PaymentStatus before = payment.status;
        SctInstStatusClient.RailStatus rail;
        try {
            rail = sctInstStatus.get(paymentId);
        } catch (Exception e) {
            return Response.status(202)
                    .entity(new ReconciliationResponse(paymentId, before.name(), "UNAVAILABLE", payment.status.name(), payment.settlementId))
                    .build();
        }

        if ("SETTLED".equals(rail.status())) {
            payment.status = PaymentStatus.SETTLED;
            payment.settlementId = rail.settlementId();
            payment.lastError = null;
            payment.updatedAt = Instant.now();
            recordSettlementLedger(payment);
        }

        return Response.ok(new ReconciliationResponse(
                paymentId,
                before.name(),
                rail.status(),
                payment.status.name(),
                payment.settlementId))
                .build();
    }

    private static void recordSettlementLedger(PaymentEntity payment) {
        long existing = LedgerEntryEntity.count("paymentId = ?1 and entryType = ?2", payment.paymentId, "SETTLEMENT");
        if (existing > 0) {
            return;
        }
        LedgerEntryEntity entry = new LedgerEntryEntity();
        entry.paymentId = payment.paymentId;
        entry.entryType = "SETTLEMENT";
        entry.amountCents = payment.amountCents;
        entry.currency = payment.currency;
        entry.settlementId = payment.settlementId;
        entry.createdAt = Instant.now();
        entry.persist();
    }

    private static boolean samePayload(PaymentEntity p, PaymentRequest r) {
        return Objects.equals(p.paymentId, r.paymentId())
                && p.amountCents == r.amountCents()
                && Objects.equals(p.currency, r.currency() == null ? null : r.currency().toUpperCase())
                && Objects.equals(p.debtorAlias, r.debtorAlias())
                && Objects.equals(p.creditorAlias, r.creditorAlias())
                && Objects.equals(p.simulateMode, r.simulateMode());
    }

    private static boolean blank(String value) {
        return value == null || value.isBlank();
    }

    private static String truncate(String value, int max) {
        if (value == null || value.length() <= max) return value;
        return value.substring(0, max);
    }

    private static PaymentResponse toResponse(PaymentEntity p) {
        return new PaymentResponse(p.paymentId, p.status.name(), p.settlementId);
    }

    private static PaymentDetails toDetails(PaymentEntity p) {
        return new PaymentDetails(
                p.paymentId,
                p.idempotencyKey,
                p.amountCents,
                p.currency,
                p.debtorAlias,
                p.creditorAlias,
                p.status.name(),
                p.settlementId,
                p.lastError,
                p.createdAt,
                p.updatedAt);
    }

    public record PaymentRequest(
            String paymentId,
            long amountCents,
            String currency,
            String debtorAlias,
            String creditorAlias,
            String simulateMode) {}

    public record PaymentResponse(String paymentId, String status, String settlementId) {}

    public record PaymentDetails(
            String paymentId,
            String idempotencyKey,
            long amountCents,
            String currency,
            String debtorAlias,
            String creditorAlias,
            String status,
            String settlementId,
            String lastError,
            Instant createdAt,
            Instant updatedAt) {}

    public record LedgerEntryView(
            Long id,
            String paymentId,
            String entryType,
            long amountCents,
            String currency,
            String settlementId,
            Instant createdAt) {}

    public record ReconciliationResponse(
            String paymentId,
            String beforeStatus,
            String railStatus,
            String afterStatus,
            String settlementId) {}

    public record ErrorResponse(String code, String message) {}
}
