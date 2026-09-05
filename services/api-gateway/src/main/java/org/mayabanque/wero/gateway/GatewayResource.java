package org.mayabanque.wero.gateway;

import io.opentelemetry.api.trace.Span;
import jakarta.annotation.security.RolesAllowed;
import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import java.util.UUID;
import org.eclipse.microprofile.rest.client.inject.RestClient;
import org.jboss.logging.Logger;

@Path("/api")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
public class GatewayResource {

    private static final Logger LOG = Logger.getLogger(GatewayResource.class);

    @Inject @RestClient PaymentBackendClient paymentBackend;
    @Inject @RestClient AuditBackendClient auditBackend;

    @POST @Path("/consents") @RolesAllowed("consent-create")
    public Response createConsent(@HeaderParam("Authorization") String authorization,
                                  @HeaderParam("X-Correlation-Id") String correlationId,
                                  String body) {
        String cid = observe(correlationId, "consent.create");
        return relay(paymentBackend.createConsent(authorization, cid, body), cid);
    }

    @GET @Path("/consents/{consentId}") @RolesAllowed({"consent-create", "consent-sca", "payment-read"})
    public Response getConsent(@HeaderParam("Authorization") String authorization,
                               @HeaderParam("X-Correlation-Id") String correlationId,
                               @PathParam("consentId") String consentId) {
        String cid = observe(correlationId, "consent.read");
        return relay(paymentBackend.getConsent(authorization, cid, consentId), cid);
    }

    @POST @Path("/consents/{consentId}/sca") @RolesAllowed("consent-sca")
    public Response verifySca(@HeaderParam("Authorization") String authorization,
                              @HeaderParam("X-Correlation-Id") String correlationId,
                              @PathParam("consentId") String consentId,
                              String body) {
        String cid = observe(correlationId, "consent.sca");
        return relay(paymentBackend.verifySca(authorization, cid, consentId, body), cid);
    }

    @POST @Path("/payments/single-immediate") @RolesAllowed("payment-create")
    public Response createPayment(@HeaderParam("Authorization") String authorization,
                                  @HeaderParam("X-Correlation-Id") String correlationId,
                                  @HeaderParam("Idempotency-Key") String idempotencyKey,
                                  @HeaderParam("X-Consent-Id") String consentId,
                                  String body) {
        String cid = observe(correlationId, "payment.create");
        return relay(paymentBackend.createPayment(authorization, cid, idempotencyKey, consentId, body), cid);
    }

    @GET @Path("/payments/{paymentId}") @RolesAllowed("payment-read")
    public Response getPayment(@HeaderParam("Authorization") String authorization,
                               @HeaderParam("X-Correlation-Id") String correlationId,
                               @PathParam("paymentId") String paymentId) {
        String cid = observe(correlationId, "payment.read");
        Span.current().setAttribute("wero.payment_id", paymentId);
        return relay(paymentBackend.getPayment(authorization, cid, paymentId), cid);
    }

    @GET @Path("/payments/{paymentId}/ledger") @RolesAllowed("payment-read")
    public Response getLedger(@HeaderParam("Authorization") String authorization,
                              @HeaderParam("X-Correlation-Id") String correlationId,
                              @PathParam("paymentId") String paymentId) {
        String cid = observe(correlationId, "ledger.read");
        Span.current().setAttribute("wero.payment_id", paymentId);
        return relay(paymentBackend.getLedger(authorization, cid, paymentId), cid);
    }

    @POST @Path("/payments/{paymentId}/reconcile") @RolesAllowed("payment-reconcile")
    public Response reconcile(@HeaderParam("Authorization") String authorization,
                              @HeaderParam("X-Correlation-Id") String correlationId,
                              @PathParam("paymentId") String paymentId) {
        String cid = observe(correlationId, "payment.reconcile");
        Span.current().setAttribute("wero.payment_id", paymentId);
        return relay(paymentBackend.reconcile(authorization, cid, paymentId), cid);
    }

    @GET @Path("/outbox/{paymentId}") @RolesAllowed("payment-read")
    public Response getOutbox(@HeaderParam("Authorization") String authorization,
                              @HeaderParam("X-Correlation-Id") String correlationId,
                              @PathParam("paymentId") String paymentId) {
        String cid = observe(correlationId, "outbox.read");
        Span.current().setAttribute("wero.payment_id", paymentId);
        return relay(paymentBackend.getOutbox(authorization, cid, paymentId), cid);
    }

    @GET @Path("/audit/events/{paymentId}") @RolesAllowed("audit-read")
    public Response getAudit(@HeaderParam("Authorization") String authorization,
                             @HeaderParam("X-Correlation-Id") String correlationId,
                             @PathParam("paymentId") String paymentId) {
        String cid = observe(correlationId, "audit.read");
        Span.current().setAttribute("wero.payment_id", paymentId);
        return relay(auditBackend.byPayment(authorization, cid, paymentId), cid);
    }

    private static String observe(String supplied, String operation) {
        String cid = supplied == null || supplied.isBlank() ? UUID.randomUUID().toString() : supplied;
        Span.current().setAttribute("wero.correlation_id", cid);
        Span.current().setAttribute("wero.operation", operation);
        LOG.infof("correlationId=%s operation=%s", cid, operation);
        return cid;
    }

    private static Response relay(Response downstream, String correlationId) {
        int status = downstream.getStatus();
        String entity = downstream.hasEntity() ? downstream.readEntity(String.class) : null;
        String replay = downstream.getHeaderString("X-Idempotent-Replay");
        MediaType mediaType = downstream.getMediaType();
        downstream.close();

        Response.ResponseBuilder builder = Response.status(status)
                .header("X-Correlation-Id", correlationId)
                .header("Cache-Control", "no-store");
        var spanContext = Span.current().getSpanContext();
        if (spanContext.isValid()) {
            builder.header("X-Trace-Id", spanContext.getTraceId());
        }
        if (entity != null && !entity.isBlank()) {
            builder.entity(entity);
            builder.type(mediaType != null ? mediaType : MediaType.APPLICATION_JSON_TYPE);
        }
        if (replay != null) builder.header("X-Idempotent-Replay", replay);
        return builder.build();
    }
}
