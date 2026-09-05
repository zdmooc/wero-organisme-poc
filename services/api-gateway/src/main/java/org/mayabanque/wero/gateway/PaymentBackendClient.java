package org.mayabanque.wero.gateway;

import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

@Path("/")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
@RegisterRestClient(configKey = "payment-backend")
public interface PaymentBackendClient {

    @POST
    @Path("/consents")
    Response createConsent(
            @HeaderParam("Authorization") String authorization,
            @HeaderParam("X-Correlation-Id") String correlationId,
            String body);

    @GET
    @Path("/consents/{consentId}")
    Response getConsent(
            @HeaderParam("Authorization") String authorization,
            @HeaderParam("X-Correlation-Id") String correlationId,
            @PathParam("consentId") String consentId);

    @POST
    @Path("/consents/{consentId}/sca")
    Response verifySca(
            @HeaderParam("Authorization") String authorization,
            @HeaderParam("X-Correlation-Id") String correlationId,
            @PathParam("consentId") String consentId,
            String body);

    @POST
    @Path("/payments/single-immediate")
    Response createPayment(
            @HeaderParam("Authorization") String authorization,
            @HeaderParam("X-Correlation-Id") String correlationId,
            @HeaderParam("Idempotency-Key") String idempotencyKey,
            @HeaderParam("X-Consent-Id") String consentId,
            String body);

    @GET
    @Path("/payments/{paymentId}")
    Response getPayment(
            @HeaderParam("Authorization") String authorization,
            @HeaderParam("X-Correlation-Id") String correlationId,
            @PathParam("paymentId") String paymentId);

    @GET
    @Path("/payments/{paymentId}/ledger")
    Response getLedger(
            @HeaderParam("Authorization") String authorization,
            @HeaderParam("X-Correlation-Id") String correlationId,
            @PathParam("paymentId") String paymentId);

    @POST
    @Path("/payments/{paymentId}/reconcile")
    Response reconcile(
            @HeaderParam("Authorization") String authorization,
            @HeaderParam("X-Correlation-Id") String correlationId,
            @PathParam("paymentId") String paymentId);

    @GET
    @Path("/outbox/{paymentId}")
    Response getOutbox(
            @HeaderParam("Authorization") String authorization,
            @HeaderParam("X-Correlation-Id") String correlationId,
            @PathParam("paymentId") String paymentId);
}
